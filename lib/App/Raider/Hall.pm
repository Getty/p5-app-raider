package App::Raider::Hall;
our $VERSION = '0.004';
# ABSTRACT: Hall daemon — spawns and manages raider processes

=head1 SYNOPSIS

    use App::Raider::Hall;
    my $hall = App::Raider::Hall->new(root => Path::Tiny::path('.'));
    $hall->run;   # blocks on the IO::Async loop

From the shell:

    raider hall init --name bjorn
    raider hall start --daemon --acp-port 38421
    raider hall spawn bjorn "summarise today's git log"

=head1 DESCRIPTION

Hall is the multi-raider daemon. It owns a UNIX command/event socket,
spawns named raiders as child processes, enforces C<1name> singleton
slots with persistent FIFO queueing, and wires in optional Slice 4/5
features:

=over

=item * Non-blocking L<Schedule::Cron> scheduler for timed raids.

=item * Multi-bot Telegram long-poll with routing + per-chat history.

=item * MCP tool catalog on C<.raider-hall.mcp>.

=item * ACP (Agent Client Protocol) adapter on a TCP port for Zed and
other ACP-capable clients — see L<App::Raider::Hall::ACP>.

=back

All state flows through the event bus (JSONL pub/sub). Clients
subscribe with C<{type: subscribe, payload: {filter: 'raider.'}}> and
commands are separate frames (C<{type: command, payload: {cmd: ...}}>).

=head1 CONFIG FILE

C<.raider-hall.yml> in the hall root:

    longhouse: false
    preferred_lib_target: .raider-hall/lib
    raiders:
      bjorn:   { engine: anthropic, persona: caveman }
      lagertha:{ engine: openai,    persona: polite, packs: [git-guru] }
    cron:
      - { name: 1bjorn, cron: '*/15 * * * *', mission: 'ping CI' }
    telegram:
      bots:
        ops: { token: '...', allowlist: [42], routing: { '*': lagertha } }
    acp: { port: 38421, host: 127.0.0.1 }
    mcp: { enable: 1 }

=head1 SEE ALSO

L<App::Raider>, L<App::Raider::Hall::ACP>, L<App::Raider::HallTools>,
L<App::Raider::Hall::CLI>.

=cut

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

has acp_adapter => (
  is => 'ro',
  lazy => 1,
  builder => '_build_acp_adapter',
);

sub _build_acp_adapter {
  my ($self) = @_;
  require App::Raider::Hall::ACP;
  my $conf = $self->config->{acp} // {};
  App::Raider::Hall::ACP->new(
    hall => $self,
    port => ($ENV{RAIDER_HALL_ACP_PORT} // $conf->{port} // 0),
    host => ($ENV{RAIDER_HALL_ACP_HOST} // $conf->{host} // '127.0.0.1'),
  );
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
  $self->_setup_acp;

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

  my $sock = IO::Socket::UNIX->new(
    Local => $path,
    Listen => 1,
  ) or die "Cannot create UNIX socket at $path: $!";

  chmod 0600, $path or die "Cannot chmod 0600 $path: $!";

  my $listener = IO::Async::Listener->new(
    on_accept => sub {
      my ($listener, $sock, $peeraddr) = @_;
      $self->_handle_client($sock);
    },
  );

  $loop->add($listener);

  $listener->listen(handle => $sock);
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

sub _setup_acp {
  my ($self) = @_;
  my $enabled = $ENV{RAIDER_HALL_ACP_PORT}
    || ($self->config->{acp} && $self->config->{acp}{port});
  return unless $enabled;
  $self->acp_adapter->start;
}

sub _acp_running {
  my ($self) = @_;
  return $ENV{RAIDER_HALL_ACP_PORT}
    || ($self->config->{acp} && $self->config->{acp}{port});
}

sub _handle_client {
  my ($self, $sock) = @_;
  my $stream = IO::Async::Stream->new(
    handle => $sock,
    on_read => sub {
      my ($stream, $bufref, $eof) = @_;
      $self->_process_client_frames($stream, $bufref, $eof);
    },
    on_closed => sub {
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

  # CHLD is handled per-process via IO::Async::Process->on_finish; no
  # global watcher needed (and mixing would double-reap).

  $loop->watch_signal(TERM => sub { $self->shutdown });
  $loop->watch_signal(INT  => sub { $self->shutdown });
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

  my $raider_bin = $self->_raider_bin;
  my @cmd = ($^X, $raider_bin, '--json');
  push @cmd, '--engine', $engine if $engine;
  push @cmd, '--model', $model if $model;
  push @cmd, '--pack', $_ for @$packs;
  push @cmd, '--root', $self->root->stringify;
  # Mission is one single argv (bin/raider does join(' ', @ARGV)).
  push @cmd, '--', $mission;

  my $log_dir = $self->root->child('.raider-hall', 'logs');
  $log_dir->mkpath unless -d $log_dir;

  require IO::Async::Process;
  my $log_path = $log_dir->child("${slot}.log");

  my $lib_path = $self->_raider_lib_path($base_name);
  my $extra_perl5lib = join ':', grep { defined && length } ($lib_path,
    ($self->config->{longhouse} ? $self->longhouse_lib_path->stringify : ()));

  my $process = IO::Async::Process->new(
    command => \@cmd,
    setup => [
      stdin  => [ 'open', '<', '/dev/null' ],
      stdout => [ 'open', '>>', "$log_path" ],
      stderr => [ 'open', '>>', "$log_path" ],
      env => {
        %ENV,
        RAIDER_HALL_MODE   => '1',
        RAIDER_HALL_ROOT   => $self->root->stringify,
        RAIDER_HALL_SLOT   => $slot,
        RAIDER_HALL_SOCKET => $self->socket_path,
        PERL5LIB => join(':', grep { defined && length }
                          ($ENV{PERL5LIB}, $extra_perl5lib)),
      },
    ],
    on_finish => sub {
      my ($proc, $exitcode) = @_;
      my $pid = $proc->pid;
      $self->loop->later(sub { $self->_reap_raider($pid, $exitcode) });
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

sub _raider_bin {
  my ($self) = @_;
  # Explicit override wins — useful in tests and non-standard installs.
  return $ENV{RAIDER_HALL_RAIDER_BIN}
    if $ENV{RAIDER_HALL_RAIDER_BIN} && -x $ENV{RAIDER_HALL_RAIDER_BIN};

  # Otherwise: next to the currently-running script (raider-hall lives
  # alongside raider in a normal install), then $PATH.
  my $here = path($0)->absolute;
  my $sibling = $here->parent->child('raider');
  return $sibling->stringify if -x $sibling;
  require File::Which;
  my $which = File::Which::which('raider');
  return $which if $which;
  die "Cannot find 'raider' binary (set RAIDER_HALL_RAIDER_BIN or put it in \$PATH)";
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

  if ($self->_acp_running) {
    eval { $self->acp_adapter->stop };
  }

  if ($self->telegram) {
    eval { $self->telegram->stop };
  }

  for my $r (values %{$self->raiders}) {
    kill 'TERM', $r->pid if $r->pid && $r->pid > 0;
  }

  require IO::Async::Timer::Countdown;
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
  $timer->start;

  # With no children running, stop immediately rather than waiting the
  # full 5s grace period.
  if (!keys %{$self->raiders}) {
    $self->loop->later(sub { $self->loop->stop });
  }
}

sub _write_pidfile {
  my ($self) = @_;
  my $pidfile = $self->root->child('.raider-hall.pid');
  $pidfile->spew_utf8("$$\n");
}

sub _remove_pidfile {
  my ($self) = @_;
  return unless $self->root;
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

# Non-blocking cron: for each entry we compute the next execution time via
# Schedule::Cron and arm an IO::Async::Timer::Absolute. When it fires we
# spawn the raider, then re-arm for the following occurrence. Overlap is
# controlled per-entry: default is hall's 1name queue (opt-in coalesce
# drops the run if the previous is still in-flight).

use Moose;
use namespace::autoclean;
use Schedule::Cron;
use IO::Async::Timer::Absolute;

has hall => (
  is => 'ro',
  isa => 'App::Raider::Hall',
  required => 1,
  weak_ref => 1,
);

has _jobs => (
  is => 'ro',
  default => sub { {} },
);

# A single parsing helper — we only use Schedule::Cron to compute the next
# time from the expression; we never call its own run loop.
sub _next_time_for {
  my ($self, $expr) = @_;
  my $sc = Schedule::Cron->new(sub { }, nofork => 1);
  my $idx = $sc->add_entry($expr, sub { });
  return $sc->get_next_execution_time($expr);
}

sub add_job {
  my ($self, %args) = @_;
  my $id = $args{id} // die "need id";
  my $cron_expr = $args{cron} // die "need cron expr";
  my $name = $args{name} // die "need name";
  my $mission = $args{mission} // '';
  my $coalesce = $args{coalesce} // 0;

  $self->_jobs->{$id} = {
    id => $id,
    cron => $cron_expr,
    name => $name,
    mission => $mission,
    coalesce => $coalesce,
    running => 0,
  };
  $self->_arm($id);
  return $id;
}

sub _arm {
  my ($self, $id) = @_;
  my $job = $self->_jobs->{$id} or return;
  my $when = eval { $self->_next_time_for($job->{cron}) };
  return unless $when;

  my $timer = IO::Async::Timer::Absolute->new(
    time => $when,
    on_expire => sub {
      my $t = $self->_jobs->{$id};
      return unless $t;  # cancelled
      if ($t->{coalesce} && $t->{running}) {
        $self->hall->_emit('cron.coalesced', { id => $id, name => $t->{name} });
      } else {
        $t->{running} = 1;
        my $res = eval { $self->hall->spawn(name => $t->{name}, mission => $t->{mission}) };
        $self->hall->_emit('cron.fired', {
          id => $id, name => $t->{name},
          ($res && $res->{id} ? (raider_id => $res->{id}) : ()),
        });
        # Clear running once the spawn returned a handle; 1name queueing
        # owns overlap protection when coalesce is off.
        $t->{running} = 0;
      }
      $self->_arm($id);  # re-schedule next occurrence
    },
  );
  $job->{timer} = $timer;
  $self->hall->loop->add($timer);
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
}

sub cancel_job {
  my ($self, $id) = @_;
  my $job = delete $self->_jobs->{$id} or return;
  if ($job->{timer}) {
    eval { $self->hall->loop->remove($job->{timer}) };
  }
}

__PACKAGE__->meta->make_immutable;

1;

# ===== Hall::Telegram — Multi-bot Telegram long-poll =====

package App::Raider::Hall::Telegram;
our $VERSION = '0.004';

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;
use URI;
use HTTP::Request::Common ();
use IO::Async::Timer::Countdown;

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
    timeout => 60,
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

  my $uri = URI->new("https://api.telegram.org/bot$token/getUpdates");
  my %q = (timeout => 30);
  $q{offset} = $worker->{offset} if $worker->{offset};
  $uri->query_form(%q);

  my $f = $ua->GET($uri);
  $f->on_done(sub {
    my ($resp) = @_;
    my $updates = eval {
      JSON::MaybeXS->new->decode($resp->decoded_content)->{result} // []
    } // [];
    for my $update (@$updates) {
      $self->_handle_update($name, $update);
      $worker->{offset} = $update->{update_id} + 1;
    }
    $self->hall->loop->later(sub { $self->_poll($name) });
  });
  $f->on_fail(sub {
    $self->hall->_emit('telegram.poll_error', { bot => $name, error => "$_[0]" });
    # Back off a bit on failure so we don't hot-loop against a dead network.
    my $timer = IO::Async::Timer::Countdown->new(
      delay => 5,
      on_expire => sub { $self->_poll($name) },
    );
    $self->hall->loop->add($timer);
    $timer->start;
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

  my $uri = URI->new("https://api.telegram.org/bot$token/sendMessage");
  my $req = HTTP::Request::Common::POST($uri, [
    chat_id => $chat_id,
    text => $text,
    parse_mode => 'Markdown',
  ]);

  # Fire-and-forget: return the Future so callers can await if they want.
  my $f = $ua->do_request(request => $req);
  $f->on_fail(sub {
    $self->hall->_emit('telegram.send_error', {
      bot => $bot_name, chat_id => $chat_id, error => "$_[0]",
    });
  });
  return { ok => 1, future => $f };
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
      slots => [sort keys %{$hall->raiders}],
    }) . "\n");
  });

  $hall->_register_cmd(telegram_reply => sub {
    my ($hall, $stream, $payload) = @_;
    my $bot = $payload->{bot} // '';
    my $chat_id = $payload->{chat_id};
    my $text = $payload->{text} // '';
    my $result;
    if (!$bot || !defined $chat_id || !length $text) {
      $result = { error => 'telegram_reply requires bot, chat_id, text' };
    }
    elsif (!$hall->config->{telegram} || !$hall->config->{telegram}{bots}) {
      $result = { error => 'telegram not configured in .raider-hall.yml' };
    }
    else {
      $result = $hall->telegram->send_message(
        bot => $bot, chat_id => $chat_id, text => $text,
      );
      # Strip the Future before serialising.
      delete $result->{future};
    }
    $stream->write(JSON::MaybeXS->new->encode($result) . "\n");
  });
}

1;