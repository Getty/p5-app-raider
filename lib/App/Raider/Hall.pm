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

  my %env = %ENV;
  $env{RAIDER_HALL_MODE} = '1';
  $env{RAIDER_HALL_ROOT} = $self->root->stringify;
  $env{RAIDER_HALL_SLOT} = $slot;
  $env{PERL5LIB} = join ':', grep { defined } (
    $env{PERL5LIB},
    $self->_raider_lib_path($base_name),
    ($self->config->{longhouse} ? $self->longhouse_lib_path->stringify : ()),
  );

  my $log_dir = $self->root->child('.raider-hall', 'logs');
  $log_dir->mkpath unless -d $log_dir;

  require IO::Async::Process;
  my $process = IO::Async::Process->new(
    command => \@cmd,
    env => \%env,
    stdout => {
      to => [qw( append /dev/null )],
      ( -f '/dev/null' ? () : (into => '/dev/null') ),
    },
    stderr => {
      to => [qw( append /dev/null )],
      ( -f '/dev/null' ? () : (into => '/dev/null') ),
    },
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
  $self->_remove_pidfile if defined $$self;
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

__PACKAGE__->meta->make_immutable;

1;

package App::Raider::Hall::CLI;
our $VERSION = '0.004';
# ABSTRACT: raider hall subcommand dispatcher

use strict;
use warnings;
use Path::Tiny;
use Getopt::Long qw( GetOptionsFromArray );
use JSON::MaybeXS ();
use IO::Async::Loop;
use POSIX qw(WNOHANG);

my @subcommands = qw( init start stop status ps spawn attach logs kill );

sub main {
  my ($class, @args) = @_;

  if (!@args || $args[0] eq '--help' || $args[0] eq '-h') {
    print usage();
    exit 0;
  }

  my $cmd = shift @args;

  if ($cmd eq 'init')    { shift @args; return run_init(@args); }
  if ($cmd eq 'start')   { shift @args; return run_start(@args); }
  if ($cmd eq 'stop')    { shift @args; return run_stop(@args); }
  if ($cmd eq 'status')  { shift @args; return run_status(@args); }
  if ($cmd eq 'ps')      { shift @args; return run_ps(@args); }
  if ($cmd eq 'spawn')   { shift @args; return run_spawn(@args); }
  if ($cmd eq 'attach')  { shift @args; return run_attach(@args); }
  if ($cmd eq 'logs')    { shift @args; return run_logs(@args); }
  if ($cmd eq 'kill')    { shift @args; return run_kill(@args); }
  if ($cmd eq 'help')    { print usage(); exit 0; }

  die "Unknown subcommand: $cmd\n\n" . usage();
}

sub cwd {
  path('.')->absolute->stringify;
}

sub hall_dir {
  my (@args) = @_;
  return cwd unless @args && $args[0] !~ /^-/;
  my $d = shift @args;
  return path($d // '.')->absolute->stringify;
}

sub usage {
  return <<"EOF";
Usage: raider hall <subcommand> [options]

Subcommands:
  init              Bootstrap a new hall in the current directory
  start [DIR]       Start the hall daemon (default: cwd)
  stop [DIR]        Stop the hall daemon
  status [DIR]      Show hall status
  ps [DIR]          List running raiders
  spawn [DIR] NAME MISSION  Spawn a raider
  attach [DIR] ID   Attach to a raider's event stream
  logs [DIR] ID     Fetch raider logs
  kill [DIR] ID     Terminate a raider
  help              Show this help

Run 'raider hall <subcommand> --help' for per-command options.
EOF
}

sub run_init {
  my (@args) = @_;
  my %opt;
  GetOptionsFromArray(\@_, \%opt, 'name=s', 'engine=s', 'persona=s', 'help');
  return print_init_help() if $opt{help};

  my $name = $opt{name};
  if (!$name) {
    print "Raider name (e.g. Bjorn, Ragnar, Astrid, Ivar, Lagertha): ";
    $name = <STDIN>;
    chomp $name;
    exit 1 unless length $name;
  }

  my $engine = $opt{engine} // 'anthropic';
  my $persona = $opt{persona} // 'caveman';
  my $dir = cwd;

  my %yml;
  $yml{longhouse} = 0;
  $yml{preferred_lib_target} = '.raider-hall/lib';
  $yml{raiders}{$name} = {
    engine => $engine,
    persona => $persona,
    packs => [],
    mcp => [],
    isolated => 0,
  };

  require YAML::PP;
  my $cfg_file = path($dir)->child('.raider-hall.yml');
  if (-f $cfg_file) {
    die "Refusing to overwrite existing $cfg_file\n";
  }
  $cfg_file->spew_utf8(YAML::PP->new->dump(\%yml));

  print "Hall initialised in $dir with raider '$name'.\n";
  print "Start with: raider hall start\n";
  return 0;
}

sub print_init_help {
  print <<"EOF";
raider hall init [--name NAME] [--engine ENGINE] [--persona PERSONA]

Bootstrap a new hall directory with a starter .raider-hall.yml.
Prompts interactively if --name not provided.
EOF
  exit 0;
}

sub run_start {
  my (@args) = @_;
  my %opt;
  GetOptionsFromArray(\@_, \%opt, 'daemon', 'help');
  return print_start_help() if $opt{help};

  my $dir = hall_dir(@args);
  $dir = path($dir);

  my $pidfile = $dir->child('.raider-hall.pid');
  if (-f $pidfile) {
    my $pid = eval { $pidfile->slurp_utf8 };
    if ($pid && $pid =~ /^\d+$/ && kill(0, $pid)) {
      die "Hall already running with PID $pid\n";
    }
  }

  require App::Raider::Hall;
  my $hall = App::Raider::Hall->new(root => $dir);

  if ($opt{daemon}) {
    my $pid = fork;
    die "fork failed: $!" unless defined $pid;
    if ($pid != 0) {
      print "Hall started with PID $pid\n";
      exit 0;
    }
    eval {
      POSIX::setsid() or die "setsid: $!";
      open STDIN, '<', '/dev/null';
      open STDOUT, '>', '/dev/null';
      open STDERR, '>', '/dev/null';
    };
    $hall->_write_pidfile;
  }

  eval { $hall->run };
  if ($@) {
    die "Hall error: $@\n";
  }
  return 0;
}

sub print_start_help {
  print <<"EOF";
raider hall start [DIR] [--daemon]

Start the hall daemon in DIR (default: cwd).
--daemon   Fork to background
EOF
  exit 0;
}

sub run_stop {
  my (@args) = @_;
  my $dir = hall_dir(@args);
  $dir = path($dir);

  my $pidfile = $dir->child('.raider-hall.pid');
  if (!-f $pidfile) {
    die "No PID file found. Is the hall running?\n";
  }
  my $pid = eval { $pidfile->slurp_utf8 };
  if (!$pid || $pid !~ /^\d+$/) {
    die "Invalid PID file\n";
  }
  kill 'TERM', $pid or die "Failed to send TERM to $pid: $!\n";
  print "Sent TERM to hall PID $pid\n";
  return 0;
}

sub run_status {
  my (@args) = @_;
  my $dir = hall_dir(@args);
  my $socket = path($dir)->child('.raider-hall.socket');
  die "Hall not running (no socket found)\n" unless -e $socket;

  my $result = _send_command($socket, { type => 'command', payload => { cmd => 'status' } });
  print JSON::MaybeXS->new(pretty => 1)->encode($result), "\n";
  return 0;
}

sub run_ps {
  my (@args) = @_;
  my $dir = hall_dir(@args);
  my $socket = path($dir)->child('.raider-hall.socket');
  die "Hall not running (no socket found)\n" unless -e $socket;

  my $result = _send_command($socket, { type => 'command', payload => { cmd => 'ps' } });
  my $list = $result->{raiders} // [];
  if (!@$list) {
    print "No running raiders.\n";
    return 0;
  }
  printf "%-10s %-8s %s\n", 'SLOT', 'PID', 'BASE_NAME';
  for my $r (@$list) {
    printf "%-10s %-8s %s\n", $r->{slot}, $r->{pid}, $r->{base_name};
  }
  return 0;
}

sub _send_command {
  my ($socket_path, $msg) = @_;

  my $loop = IO::Async::Loop->new;

  my $result;
  my $connected;
  my $done;

  my $connector = $loop->connect(
    path => "$socket_path",
    on_connected => sub {
      my ($sock) = @_;
      $connected = 1;
      my $json = JSON::MaybeXS->new->encode($msg);
      $sock->write("$json\n");
    },
    on_read => sub {
      my ($sock, $bufref) = @_;
      if ($$bufref =~ s/^(.*?)\n//) {
        $result = JSON::MaybeXS->new->decode($1);
        $done = 1;
        $loop->stop;
      }
    },
    on_close => sub {
      $loop->stop if $connected && !$done;
    },
    on_error => sub {
      my ($err) = @_;
      die "Connection error: $err\n";
    },
  );

  $loop->add($connector);
  $loop->run;

  die "No response from hall\n" unless $result;
  return $result;
}

sub run_spawn {
  my (@args) = @_;
  my %opt;
  GetOptionsFromArray(\@_, \%opt, 'attach', 'help');
  return print_spawn_help() if $opt{help};

  my $dir = hall_dir(@args);
  die "Usage: raider hall spawn NAME MISSION [--attach]\n" unless @args >= 2;

  my $name = shift @args;
  my $mission = join ' ', @args;

  my $socket = path($dir)->child('.raider-hall.socket');
  die "Hall not running (no socket found)\n" unless -e $socket;

  my $result = _send_command($socket, {
    type => 'command',
    payload => {
      cmd => 'spawn',
      name => $name,
      mission => $mission,
      attach => $opt{attach} ? 1 : 0,
    },
  });

  if ($result->{queued}) {
    print "Mission queued for slot $result->{slot} (queue depth: $result->{queue_depth}).\n";
  }
  elsif ($result->{id}) {
    print "Spawned raider $result->{id} (PID $result->{pid}) in slot $result->{slot}.\n";
  }
  elsif ($result->{error}) {
    my $e = JSON::MaybeXS->new->decode($result->{error});
    die "Hall error: $e->{error}\n";
  }
  return 0;
}

sub print_spawn_help {
  print <<"EOF";
raider hall spawn [DIR] NAME MISSION [--attach]

Spawn a raider with the given NAME and MISSION in DIR (default: cwd).
EOF
  exit 0;
}

sub run_attach {
  my (@args) = @_;
  my %opt;
  GetOptionsFromArray(\@_, \%opt, 'help');
  return print_attach_help() if $opt{help};

  my $dir = hall_dir(@args);
  die "Usage: raider hall attach ID\n" unless @args;

  my $id = shift @args;
  my $socket = path($dir)->child('.raider-hall.socket');
  die "Hall not running (no socket found)\n" unless -e $socket;

  my $result = _send_command($socket, {
    type => 'command',
    payload => { cmd => 'attach', id => $id },
  });

  if ($result->{error}) {
    die "Hall: $result->{error}\n";
  }

  print "Raider $id:\n";
  print "  slot:   $result->{slot}\n";
  print "  PID:    $result->{pid}\n";
  print "  log:    $result->{log_path}\n";
  return 0;
}

sub print_attach_help {
  print <<"EOF";
raider hall attach [DIR] ID

Attach to a raider's event stream.
EOF
  exit 0;
}

sub run_logs {
  my (@args) = @_;
  my %opt;
  GetOptionsFromArray(\@_, \%opt, 'follow', 'help');
  return print_logs_help() if $opt{help};

  my $dir = hall_dir(@args);
  die "Usage: raider hall logs ID [--follow]\n" unless @args;

  my $id = shift @args;
  my $socket = path($dir)->child('.raider-hall.socket');
  die "Hall not running (no socket found)\n" unless -e $socket;

  my $result = _send_command($socket, {
    type => 'command',
    payload => { cmd => 'logs', id => $id },
  });

  if ($result->{error}) {
    die "Hall: $result->{error}\n";
  }
  print $result->{log};
  return 0;
}

sub print_logs_help {
  print <<"EOF";
raider hall logs [DIR] ID [--follow]

Fetch logs for a raider. --follow not yet implemented.
EOF
  exit 0;
}

sub run_kill {
  my (@args) = @_;
  my %opt;
  GetOptionsFromArray(\@_, \%opt, 'help');
  return print_kill_help() if $opt{help};

  my $dir = hall_dir(@args);
  die "Usage: raider hall kill ID\n" unless @args;

  my $id = shift @args;
  my $socket = path($dir)->child('.raider-hall.socket');
  die "Hall not running (no socket found)\n" unless -e $socket;

  my $result = _send_command($socket, {
    type => 'command',
    payload => { cmd => 'kill', id => $id },
  });

  if ($result->{killed}) {
    print "Killed raider $id.\n";
  }
  elsif ($result->{error}) {
    die "Hall: $result->{error}\n";
  }
  return 0;
}

sub print_kill_help {
  print <<"EOF";
raider hall kill [DIR] ID

Terminate a raider.
EOF
  exit 0;
}

1;