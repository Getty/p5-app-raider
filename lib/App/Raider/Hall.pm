package App::Raider::Hall;
our $VERSION = '0.004';
# ABSTRACT: Hall daemon — spawns and manages raider processes

use strict;
use warnings;
use Path::Tiny;
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Timer;
use JSON::MaybeXS;
use POSIX qw(WNOHANG);
use YAML::PP;
use Moose;
use namespace::autoclean;

has root => (
  is => 'ro',
  isa => 'Path::Tiny',
  required => 1,
);

has loop => (
  is => 'ro',
  lazy => 1,
  builder => '_build_loop',
);

has _loop => (
  is => 'ro',
  init_arg => undef,
  default => sub { IO::Async::Loop->new },
);

sub _build_loop { $_[0]->_loop }

has config => (
  is => 'ro',
  isa => 'HashRef',
  lazy => 1,
  builder => '_build_config',
);

sub _build_config {
  my ($self) = @_;
  my $yml_file = $self->root->child('.raider-hall.yml');
  return {} unless -f $yml_file;
  YAML::PP->new->load_string($yml_file->slurp_utf8);
}

has socket_path => (
  is => 'ro',
  lazy => 1,
  builder => '_build_socket_path',
);

sub _build_socket_path {
  my ($self) = @_;
  $self->root->child('.raider-hall.socket')->stringify;
}

has mcpserver_socket_path => (
  is => 'ro',
  lazy => 1,
  builder => '_build_mcpserver_socket_path',
);

sub _build_mcpserver_socket_path {
  my ($self) = @_;
  $self->root->child('.raider-hall.mcp')->stringify;
}

has longhouse_lib_path => (
  is => 'ro',
  lazy => 1,
  builder => '_build_longhouse_lib_path',
);

sub _build_longhouse_lib_path {
  my ($self) = @_;
  $self->root->child('longhouse', 'lib');
}

has state_dir => (
  is => 'ro',
  lazy => 1,
  builder => '_build_state_dir',
);

sub _build_state_dir {
  my ($self) = @_;
  my $d = $self->root->child('.raider-hall', 'state');
  $d->mkpath unless -d $d;
  $d;
}

has raiders => (
  is => 'ro',
  default => sub { {} },
);

has singleton_queues => (
  is => 'ro',
  default => sub { {} },
);

has cron_scheduler => (
  is => 'ro',
  lazy => 1,
  builder => '_build_cron_scheduler',
);

sub _build_cron_scheduler {
  my ($self) = @_;
  require App::Raider::Hall::Cron;
  App::Raider::Hall::Cron->new(hall => $self);
}

has telegram => (
  is => 'ro',
  lazy => 1,
  builder => '_build_telegram',
);

sub _build_telegram {
  my ($self) = @_;
  require App::Raider::Hall::Telegram;
  App::Raider::Hall::Telegram->new(hall => $self);
}

has mcp_adapter => (
  is => 'ro',
  lazy => 1,
  builder => '_build_mcp_adapter',
);

sub _build_mcp_adapter {
  my ($self) = @_;
  require App::Raider::Hall::MCP;
  App::Raider::Hall::MCP->new(hall => $self);
}

has protocol => (
  is => 'ro',
  lazy => 1,
  builder => '_build_protocol',
);

sub _build_protocol {
  my ($self) = @_;
  my $p = App::Raider::Hall::Protocol->new(hall => $self);
  $p->setup_handlers;
  $p;
}

sub BUILD {
  my ($self) = @_;
  $self->root->mkpath unless -d $self->root;
}

sub run {
  my ($self) = @_;
  my $loop = $self->loop;

  $self->_setup_socket;
  $self->_setup_mcp_socket if $self->_want_mcp_socket;
  $self->_setup_event_broadcaster;
  $self->_load_singleton_queues;
  $self->_setup_signal_handlers;
  $self->protocol;
  $self->_setup_cron;
  $self->_setup_telegram;

  $self->_emit('hall.started', { root => $self->root->stringify });

  $loop->run;
}

sub _want_mcp_socket {
  my ($self) = @_;
  my $conf = $self->config;
  return $conf->{mcp} && $conf->{mcp}{enable};
}

sub _setup_socket {
  my ($self) = @_;
  my $loop = $self->loop;
  my $path = $self->socket_path;

  require IO::Async::Listener;
  require IO::Socket::UNIX;
  require Unix::Listen::Fancy::Sockaddr;

  my $listener = IO::Async::Listener->new(
    on_accept => sub {
      my ($listener, $sock, $peeraddr) = @_;
      $self->_handle_client($sock);
    },
  );

  $listener->listen(
    path => $path,
    max_pending => 10,
  ) or die "Cannot listen on $path: $!";

  chmod 0600, $path or die "Cannot chmod 0600 $path: $!";
  $loop->add($listener);
  $self->{_listener} = $listener;
}

sub _setup_mcp_socket {
  my ($self) = @_;
}

sub _setup_event_broadcaster {
  my ($self) = @_;
  $self->{_subscribers} = [];
}

sub _setup_cron {
  my ($self) = @_;
  return unless $self->config->{cron} && @{$self->config->{cron}};
  $self->cron_scheduler->start;
}

sub _setup_telegram {
  my ($self) = @_;
  return unless $self->config->{telegram} && $self->config->{telegram}{bots};
  $self->telegram->setup_bots;
}

sub _handle_client {
  my ($self, $sock) = @_;
  my $stream = IO::Async::Stream->new(
    handle => $sock,
    on_read => sub {
      my ($stream, $bufref, $eof) = @_;
      $self->_process_client_frames($stream, $bufref, $eof);
    },
    on_close => sub {
      my ($stream) = @_;
      $self->_unsubscribe_stream($stream);
    },
  );
  $self->loop->add($stream);
  push @{$self->{_client_streams}}, $stream;
}

sub _process_client_frames {
  my ($self, $stream, $bufref, $eof) = @_;
  return unless $$bufref =~ s/^(.*?)\n//;
  my $line = $1;
  return if $line eq '';

  my $msg = eval { JSON::MaybeXS->new->decode($line) };
  if (!$msg || $@) {
    my $err = JSON::MaybeXS->new->encode({error => "invalid JSON: $@"});
    $stream->write("$err\n");
    return;
  }

  my $type = $msg->{type} // '';
  my $payload = $msg->{payload} // {};

  if ($type eq 'subscribe') {
    push @{$self->{_subscribers}}, { stream => $stream, filter => $payload->{filter} // '' };
    return;
  }

  if ($type eq 'command') {
    $self->_handle_command($stream, $payload);
    return;
  }

  my $err = JSON::MaybeXS->new->encode({error => "unknown message type: $type"});
  $stream->write("$err\n");
}

sub _handle_command {
  my ($self, $stream, $payload) = @_;
  my $cmd = $payload->{cmd} // '';

  my $handler = $self->{_cmd_handlers}{$cmd};
  if (!$handler) {
    my $err = JSON::MaybeXS->new->encode({error => "unknown command: $cmd"});
    $stream->write("$err\n");
    return;
  }

  eval { $handler->($self, $stream, $payload) };
  if ($@) {
    my $err = JSON::MaybeXS->new->encode({error => "command failed: $@"});
    $stream->write("$err\n");
  }
}

sub _emit {
  my ($self, $type, $data) = @_;
  $data->{type} = $type;
  $data->{ts} //= time();

  my $json = JSON::MaybeXS->new->encode($data);
  my @alive;
  for my $sub (@{$self->{_subscribers}}) {
    my $filter = $sub->{filter} // '';
    next if $filter ne '' && substr($type, 0, length($filter)) ne $filter;
    my $stream = $sub->{stream};
    if ($stream && $stream->handle && $stream->handle->opened) {
      eval { $stream->write("$json\n") };
      push @alive, $sub;
    }
  }
  $self->{_subscribers} = \@alive;
}

sub _broadcast_to_socket {
  my ($self, $type, $data) = @_;
  $self->_emit($type, $data);
}

sub _unsubscribe_stream {
  my ($self, $stream) = @_;
  @{$self->{_subscribers}} = grep { $_->{stream} ne $stream } @{$self->{_subscribers}};
  @{$self->{_client_streams}} = grep { $_ ne $stream } @{$self->{_client_streams}};
}

sub _register_cmd {
  my ($self, $name, $handler) = @_;
  $self->{_cmd_handlers}{$name} = $handler;
}

sub _load_singleton_queues {
  my ($self) = @_;
  my $state_dir = $self->state_dir;
  return unless -d $state_dir;

  for my $queue_file ($state_dir->children) {
    next unless $queue_file->basename =~ /^.*\.queue\.json$/;
    my $slot = $queue_file->basename;
    $slot =~ s/\.queue\.json$//;
    next unless $slot =~ /^\d+/;
    my $q = eval { JSON::MaybeXS->new->decode($queue_file->slurp_utf8) } // [];
    $self->singleton_queues->{$slot} = $q;
  }
}

sub _persist_queue {
  my ($self, $slot) = @_;
  my $queue = $self->singleton_queues->{$slot} // [];
  my $file = $self->state_dir->child("$slot.queue.json");
  $file->spew_utf8(JSON::MaybeXS->new->encode($queue));
}

sub _setup_signal_handlers {
  my ($self) = @_;
  my $loop = $self->loop;

  $loop->sigchild(sub {
    my ($loop, $pid, $status) = @_;
    $self->_reap_raider($pid, $status);
  });

  $loop->sigterm(sub {
    my ($loop) = @_;
    $self->shutdown;
  });

  $loop->sigint(sub {
    my ($loop) = @_;
    $self->shutdown;
  });
}

sub _reap_raider {
  my ($self, $pid, $status) = @_;
  my $raider = $self->_find_raider_by_pid($pid);
  return unless $raider;

  my $slot = $raider->slot_name;
  $self->_emit('raider.done', {
    id => $raider->id,
    slot => $slot,
    pid => $pid,
    exit_code => $status >> 8,
    signaled => ($status & 127) ? 1 : 0,
  });

  delete $self->raiders->{$slot};

  if ($slot =~ /^\d+(.+)$/) {
    my $base = $1;
    my $queue = $self->singleton_queues->{$slot} // [];
    if (@$queue) {
      my $next = shift @$queue;
      $self->singleton_queues->{$slot} = $queue;
      $self->_persist_queue($slot);
      $self->_spawn_next_in_queue($slot, $base, $next);
    }
  }
}

sub _find_raider_by_pid {
  my ($self, $pid) = @_;
  for my $r (values %{$self->raiders}) {
    return $r if $r->pid && $r->pid == $pid;
  }
  return;
}

sub _spawn_next_in_queue {
  my ($self, $slot, $base_name, $mission) = @_;
  $self->_spawn_raider($slot, $base_name, $mission);
}

sub spawn {
  my ($self, %args) = @_;
  my $name = $args{name} // '';
  my $mission = $args{mission} // '';
  my $attach = $args{attach} // 0;

  my ($slot, $base_name) = $self->_parse_name($name);

  if ($slot && $self->raiders->{$slot}) {
    if ($slot =~ /^\d+(.+)$/) {
      push @{$self->singleton_queues->{$slot} //= []}, {
        mission => $mission,
        attach => $attach,
      };
      $self->_persist_queue($slot);
      $self->_emit('raider.queued', {
        slot => $slot,
        queue_depth => scalar @{$self->singleton_queues->{$slot}},
      });
      return { queued => 1, slot => $slot };
    }
    my $err = JSON::MaybeXS->new->encode({error => "slot $slot already occupied"});
    return { error => $err };
  }

  return $self->_spawn_raider($slot // $name, $base_name // $name, $mission, $attach);
}

sub _parse_name {
  my ($self, $name) = @_;
  if ($name =~ /^(\d+)([a-z][-a-z0-9]*)$/) {
    return ($1.$2, $2);
  }
  return (undef, $name);
}

sub _spawn_raider {
  my ($self, $slot, $base_name, $mission, $attach) = @_;

  my $raider_config = $self->config->{raiders}{$base_name} // {};
  my $engine = $raider_config->{engine} // 'anthropic';
  my $model = $raider_config->{model};
  my $packs = $raider_config->{packs} // [];
  my $mcp = $raider_config->{mcp} // [];
  my $isolated = $raider_config->{isolated} // 0;

  my $raider_bin = path($0)->absolute->stringify;
  my @cmd = ($^X, $raider_bin, '--json');
  push @cmd, '--engine', $engine if $engine;
  push @cmd, '--model', $model if $model;
  push @cmd, '--pack', $_ for @$packs;
  push @cmd, '--root', $self->root->stringify;
  push @cmd, '--';
  push @cmd, $mission;

  my $log_dir = $self->root->child('.raider-hall', 'logs');
  $log_dir->mkpath unless -d $log_dir;

  require IO::Async::Process;
  my $log_path = $log_dir->child("${slot}.log");

  # Set up environment for child (local so doesn't affect parent)
  local %ENV = %ENV;
  $ENV{RAIDER_HALL_MODE} = '1';
  $ENV{RAIDER_HALL_ROOT} = $self->root->stringify;
  $ENV{RAIDER_HALL_SLOT} = $slot;
  my $lib_path = $self->_raider_lib_path($base_name);
  $ENV{PERL5LIB} = join ':', grep { defined } ($ENV{PERL5LIB}, $lib_path,
    ($self->config->{longhouse} ? $self->longhouse_lib_path->stringify : ()));

  my @exec_cmd = ('/bin/sh', '-c',
    "exec >>$log_path 2>&1 && exec $^X " . join(' ', map { quotemeta($_) } @cmd)
  );
  my $process = IO::Async::Process->new(
    command => \@exec_cmd,
    on_finish => sub {
      my ($proc, $exitcode) = @_;
      my $pid = $proc->pid;
      $self->loop->later(sub { $self->_reap_raider($pid, $exitcode << 8) });
    },
  );

  $self->loop->add($process);

  my $id = "$slot-" . time;
  my $raider = App::Raider::Hall::Raider->new({
    id => $id,
    pid => $process->pid,
    slot_name => $slot,
    base_name => $base_name,
    log_path => $log_dir->child("${slot}.log"),
    mission => $mission,
  });
  $self->raiders->{$slot} = $raider;

  $self->_emit('raider.spawned', {
    id => $id,
    pid => $process->pid,
    slot => $slot,
    base_name => $base_name,
  });

  return { id => $id, pid => $process->pid, slot => $slot };
}

sub _raider_lib_path {
  my ($self, $base_name) = @_;
  if ($self->config->{longhouse}) {
    return $self->longhouse_lib_path->stringify;
  }
  return $self->root->child('.raider-hall', 'raiders', $base_name, 'lib')->stringify;
}

sub ps {
  my ($self) = @_;
  my @list;
  for my $slot (sort keys %{$self->raiders}) {
    my $r = $self->raiders->{$slot};
    push @list, {
      slot => $slot,
      pid => $r->pid,
      base_name => $r->base_name,
      mission => $r->mission,
      id => $r->id,
    };
  }
  return @list;
}

sub attach {
  my ($self, $id) = @_;
  for my $r (values %{$self->raiders}) {
    next unless $r->id eq $id;
    return {
      id => $r->id,
      slot => $r->slot_name,
      pid => $r->pid,
      log_path => $r->log_path->stringify,
    };
  }
  return { error => 'raider not found' };
}

sub kill_raider {
  my ($self, $id) = @_;
  for my $r (values %{$self->raiders}) {
    next unless $r->id eq $id;
    kill 'TERM', $r->pid if $r->pid;
    return { killed => 1, id => $id };
  }
  return { error => 'raider not found' };
}

sub logs {
  my ($self, %args) = @_;
  my $id = $args{id};
  my $slot;
  if ($id) {
    for my $s (keys %{$self->raiders}) {
      $slot = $s if $self->raiders->{$s}->id eq $id;
    }
  }
  return { error => 'raider not found' } unless $slot;

  my $log_path = $self->raiders->{$slot}->log_path;
  return { log => '' } unless -f $log_path;
  return { log => $log_path->slurp_utf8 };
}

sub shutdown {
  my ($self) = @_;
  $self->_emit('hall.stopping', {});

  if ($self->telegram) {
    eval { $self->telegram->stop };
  }

  for my $r (values %{$self->raiders}) {
    kill 'TERM', $r->pid if $r->pid && $r->pid > 0;
  }

  my $timer = IO::Async::Timer::Countdown->new(
    delay => 5,
    on_expire => sub {
      for my $r (values %{$self->raiders}) {
        kill 'KILL', $r->pid if $r->pid && $r->pid > 0;
      }
      $self->loop->stop;
    },
  );
  $self->loop->add($timer);
}

sub _write_pidfile {
  my ($self) = @_;
  my $pidfile = $self->root->child('.raider-hall.pid');
  $pidfile->spew_utf8("$$\n");
}

sub _remove_pidfile {
  my ($self) = @_;
  my $pidfile = $self->root->child('.raider-hall.pid');
  $pidfile->remove if -f $pidfile;
}

sub DEMOLISH {
  my ($self) = @_;
  $self->_remove_pidfile if $self;
}

__PACKAGE__->meta->make_immutable;

1;

package App::Raider::Hall::Raider;
our $VERSION = '0.004';

use Moose;
use namespace::autoclean;

has id => (is => 'ro', isa => 'Str', required => 1);
has pid => (is => 'ro', isa => 'Int', predicate => 'has_pid');
has slot_name => (is => 'ro', isa => 'Str', required => 1);
has base_name => (is => 'ro', isa => 'Str', required => 1);
has log_path => (is => 'ro', isa => 'Path::Tiny', required => 1);
has mission => (is => 'ro', isa => 'Str', required => 1);

__PACKAGE__->meta->make_immutable;

1;

package App::Raider::Hall::Cron;
our $VERSION = '0.004';

use Moose;
use namespace::autoclean;
use Schedule::Cron;
use JSON::MaybeXS;

has hall => (
  is => 'ro',
  isa => 'App::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

has schedule => (
  is => 'ro',
  lazy => 1,
  builder => '_build_schedule',
);

has _jobs => (
  is => 'ro',
  default => sub { {} },
);

sub _build_schedule {
  my ($self) = @_;
  Schedule::Cron->new(
    sub {
      my (@args) = @_;
      $self->_run_scheduled(@args);
    },
    nofork => 1,
  );
}

sub _run_scheduled {
  my ($self, @args) = @_;
  my $entry = $args[0] // return;
  my $name = $entry->{name} // return;
  my $mission = $entry->{mission} // '';
  my $coalesce = $entry->{coalesce} // 0;

  $self->hall->spawn(name => $name, mission => $mission);
}

sub add_job {
  my ($self, %args) = @_;
  my $id = $args{id} // time;
  my $cron_expr = $args{cron} // die "need cron expr";
  my $name = $args{name} // die "need name";
  my $mission = $args{mission} // '';
  my $coalesce = $args{coalesce} // 0;

  $self->schedule->add_entry(
    $cron_expr,
    $id,
    { name => $name, mission => $mission, coalesce => $coalesce },
  );
  $self->_jobs->{$id} = {
    cron => $cron_expr,
    name => $name,
    mission => $mission,
    coalesce => $coalesce,
  };
}

sub start {
  my ($self) = @_;
  my $conf = $self->hall->config;
  my $cron_list = $conf->{cron} // [];
  for my $entry (@$cron_list) {
    $self->add_job(
      id => $entry->{id} // $entry->{name},
      cron => $entry->{cron},
      name => $entry->{name},
      mission => $entry->{mission} // '',
      coalesce => $entry->{coalesce} // 0,
    );
  }
  $self->schedule->run;
}

sub cancel_job {
  my ($self, $id) = @_;
  delete $self->_jobs->{$id};
}

__PACKAGE__->meta->make_immutable;

1;

# ===== Hall::Telegram — Multi-bot Telegram long-poll =====

package App::Raider::Hall::Telegram;
our $VERSION = '0.004';

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;

has hall => (
  is => 'ro',
  isa => 'App::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

has _workers => (
  is => 'ro',
  default => sub { {} },
);

has _history_dir => (
  is => 'ro',
  lazy => 1,
  builder => '_build_history_dir',
);

sub _build_history_dir {
  my ($self) = @_;
  my $d = $self->hall->state_dir->child('telegram');
  $d->mkpath unless -d $d;
  $d;
}

sub setup_bots {
  my ($self) = @_;
  my $conf = $self->hall->config->{telegram} // {};
  my $bots = $conf->{bots} // {};
  for my $name (keys %$bots) {
    $self->_start_bot($name, $bots->{$name});
  }
}

sub _start_bot {
  my ($self, $name, $bot_conf) = @_;
  my $token = $bot_conf->{token} // return;
  my $allowlist = $bot_conf->{allowlist} // [];
  my $routing = $bot_conf->{routing} // {};

  require Net::Async::HTTP;
  my $ua = Net::Async::HTTP->new(
    max_connections_per_host => 1,
  );
  $self->hall->loop->add($ua);

  $self->_workers->{$name} = {
    token => $token,
    allowlist => $allowlist,
    routing => $routing,
    ua => $ua,
    offset => 0,
    active => 1,
  };

  $self->_poll($name);
}

sub _poll {
  my ($self, $name) = @_;
  my $worker = $self->_workers->{$name} or return;
  return unless $worker->{active};

  my $ua = $worker->{ua};
  my $token = $worker->{token};

  my $url = "https://api.telegram.org/bot$token/getUpdates";
  my $params = { timeout => 30 };
  $params->{offset} = $worker->{offset} if $worker->{offset};

  my $f = $ua->GET_form($url, $params);
  $f->on_done(sub {
    my ($body) = @_;
    my $updates = eval { JSON::MaybeXS->new->decode($body)->{result} // [] };
    for my $update (@$updates) {
      $self->_handle_update($name, $update);
      $worker->{offset} = $update->{update_id} + 1;
    }
    $self->hall->loop->later(sub { $self->_poll($name) });
  });
  $f->on_fail(sub {
    my ($err) = @_;
    $self->hall->loop->later(sub { $self->_poll($name) });
  });
}

sub _handle_update {
  my ($self, $bot_name, $update) = @_;
  my $worker = $self->_workers->{$bot_name} or return;
  my $msg = $update->{message} // $update->{edited_message} // return;

  my $chat_id = $msg->{chat}{id} // return;
  my $text = $msg->{text} // '';

  my $allowlist = $worker->{allowlist};
  if (@$allowlist && !grep { $_ eq $chat_id } @$allowlist) {
    return;
  }

  my $routing = $worker->{routing};
  my $target_raider = $routing->{$chat_id} // $routing->{'*'} // undef;

  $self->hall->_emit('telegram.in', {
    bot => $bot_name,
    chat_id => $chat_id,
    text => $text,
    first_name => $msg->{chat}{first_name} // '',
    username => $msg->{chat}{username} // '',
    update_id => $update->{update_id},
  });

  $self->_save_history($bot_name, $chat_id, $update);

  if ($target_raider) {
    $self->hall->spawn(
      name => $target_raider,
      mission => $text,
    );
  }
}

sub _save_history {
  my ($self, $bot_name, $chat_id, $update) = @_;
  my $dir = $self->_history_dir->child($bot_name);
  $dir->mkpath unless -d $dir;
  my $file = $dir->child("$chat_id.json");
  my $history = eval { JSON::MaybeXS->new->decode($file->slurp_utf8) } // [];
  push @$history, $update;
  $file->spew_utf8(JSON::MaybeXS->new->encode($history));
}

sub send_message {
  my ($self, %args) = @_;
  my $bot_name = $args{bot} // return { error => 'bot name required' };
  my $chat_id = $args{chat_id} // return { error => 'chat_id required' };
  my $text = $args{text} // return { error => 'text required' };

  my $worker = $self->_workers->{$bot_name} or return { error => "bot $bot_name not running" };
  my $token = $worker->{token};
  my $ua = $worker->{ua};

  my $url = "https://api.telegram.org/bot$token/sendMessage";
  my $f = $ua->POST_form($url, {
    chat_id => $chat_id,
    text => $text,
    parse_mode => 'Markdown',
  });

  my $result;
  $f->on_done(sub { $result = { ok => 1 }; });
  $f->on_fail(sub { $result = { error => $_[0] }; });
  return $result // { error => 'no response' };
}

sub stop {
  my ($self) = @_;
  $_->{active} = 0 for values %{$self->_workers};
}

__PACKAGE__->meta->make_immutable;

1;

package App::Raider::Hall::MCP;
our $VERSION = '0.004';

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;

has hall => (
  is => 'ro',
  isa => 'App::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

has socket_path => (
  is => 'ro',
  lazy => 1,
  builder => '_build_socket_path',
);

sub _build_socket_path {
  my ($self) = @_;
  $self->hall->root->child('.raider-hall.mcp')->stringify;
}

sub tools {
  my ($self) = @_;
  return {
    spawn_raider => {
      description => 'Spawn a raider in the hall',
      input => {
        type => 'object',
        properties => {
          name => { type => 'string' },
          mission => { type => 'string' },
        },
        required => [qw(name mission)],
      },
    },
    list_raiders => {
      description => 'List running raiders in the hall',
      input => { type => 'object', properties => {} },
    },
    schedule_raid => {
      description => 'Schedule a cron raid',
      input => {
        type => 'object',
        properties => {
          name => { type => 'string' },
          cron => { type => 'string' },
          mission => { type => 'string' },
          coalesce => { type => 'boolean' },
        },
        required => [qw(name cron mission)],
      },
    },
    cancel_job => {
      description => 'Cancel a scheduled job',
      input => {
        type => 'object',
        properties => { id => { type => 'string' } },
        required => [qw(id)],
      },
    },
    send_telegram => {
      description => 'Send a Telegram message',
      input => {
        type => 'object',
        properties => {
          bot => { type => 'string' },
          chat_id => { type => 'integer' },
          text => { type => 'string' },
        },
        required => [qw(bot chat_id text)],
      },
    },
    hall_status => {
      description => 'Get hall status',
      input => { type => 'object', properties => {} },
    },
  };
}

sub handle_tool_call {
  my ($self, $tool, $input) = @_;
  my $hall = $self->hall;

  if ($tool eq 'spawn_raider') {
    return $hall->spawn(name => $input->{name}, mission => $input->{mission});
  }
  if ($tool eq 'list_raiders') {
    return { raiders => [$hall->ps] };
  }
  if ($tool eq 'schedule_raid') {
    $hall->cron_scheduler->add_job(
      id => $input->{name},
      cron => $input->{cron},
      name => $input->{name},
      mission => $input->{mission},
      coalesce => $input->{coalesce} // 0,
    ) if $hall->can('cron_scheduler');
    return { scheduled => 1, name => $input->{name} };
  }
  if ($tool eq 'cancel_job') {
    $hall->cron_scheduler->cancel_job($input->{id}) if $hall->can('cron_scheduler');
    return { cancelled => 1, id => $input->{id} };
  }
  if ($tool eq 'send_telegram') {
    return $hall->telegram->send_message(
      bot => $input->{bot},
      chat_id => $input->{chat_id},
      text => $input->{text},
    ) if $hall->can('telegram');
    return { error => 'telegram not configured' };
  }
  if ($tool eq 'hall_status') {
    return {
      running => scalar(keys %{$hall->raiders}),
      root => $hall->root->stringify,
      slots => [sort keys %{$hall->raiders}],
    };
  }
  return { error => "unknown tool: $tool" };
}

__PACKAGE__->meta->make_immutable;

1;

package App::Raider::Hall::Protocol;
our $VERSION = '0.004';

use Moose;
use namespace::autoclean;

has hall => (
  is => 'ro',
  isa => 'App::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

sub setup_handlers {
  my ($self) = @_;
  my $hall = $self->hall;

  $hall->_register_cmd(spawn => sub {
    my ($hall, $stream, $payload) = @_;
    my $name = $payload->{name} // '';
    my $mission = $payload->{mission} // '';
    my $attach = $payload->{attach} // 0;
    my $result = $hall->spawn(name => $name, mission => $mission, attach => $attach);
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });

  $hall->_register_cmd(ps => sub {
    my ($hall, $stream, $payload) = @_;
    my @list = $hall->ps;
    $stream->write(JSON::MaybeXS->new->encode({raiders => \@list}) . "\n");
  });

  $hall->_register_cmd(attach => sub {
    my ($hall, $stream, $payload) = @_;
    my $id = $payload->{id} // '';
    my $info = $hall->attach($id);
    $stream->write(JSON::MaybeXS->new->encode($info) . "\n");
  });

  $hall->_register_cmd(kill => sub {
    my ($hall, $stream, $payload) = @_;
    my $id = $payload->{id} // '';
    my $result = $hall->kill_raider($id);
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });

  $hall->_register_cmd(logs => sub {
    my ($hall, $stream, $payload) = @_;
    my $id = $payload->{id} // '';
    my $result = $hall->logs(id => $id);
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });

  $hall->_register_cmd(status => sub {
    my ($hall, $stream, $payload) = @_;
    $stream->write(JSON::MaybeXS->new->encode({
      running => scalar(keys %{$hall->raiders}),
      root => $hall->root->stringify,
    }) . "\n");
  });
}

1;