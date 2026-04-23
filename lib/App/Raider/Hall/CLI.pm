package App::Raider::Hall::CLI;
our $VERSION = '0.004';
# ABSTRACT: raider hall subcommand dispatcher

use strict;
use warnings;
use Path::Tiny;
use Getopt::Long qw( GetOptions );
use JSON::MaybeXS ();
use IO::Async::Loop;
use POSIX qw(WNOHANG);

sub main {
  my ($class, @args) = @_;

  if (!@args || $args[0] eq '--help' || $args[0] eq '-h') {
    print usage();
    exit 0;
  }

  my $cmd = shift @args;

  if ($cmd eq 'init')    { return run_init(@args); }
  if ($cmd eq 'start')   { return run_start(@args); }
  if ($cmd eq 'stop')    { return run_stop(@args); }
  if ($cmd eq 'status')  { return run_status(@args); }
  if ($cmd eq 'ps')      { return run_ps(@args); }
  if ($cmd eq 'spawn')   { return run_spawn(@args); }
  if ($cmd eq 'attach')  { return run_attach(@args); }
  if ($cmd eq 'logs')    { return run_logs(@args); }
  if ($cmd eq 'kill')    { return run_kill(@args); }
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
  my @args = @_;
  my %opt;
  local @ARGV = @args;
  Getopt::Long::GetOptions(\%opt, 'name=s', 'engine=s', 'persona=s', 'help');
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
  my @args = @_;
  my %opt;
  local @ARGV = @args;
  Getopt::Long::GetOptions(\%opt, 'daemon', 'help');
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
  my @args = @_;
  my %opt;
  local @ARGV = @args;
  Getopt::Long::GetOptions(\%opt, 'attach', 'help');
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
  my @args = @_;
  my %opt;
  local @ARGV = @args;
  Getopt::Long::GetOptions(\%opt, 'help');
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
  my @args = @_;
  my %opt;
  local @ARGV = @args;
  Getopt::Long::GetOptions(\%opt, 'follow', 'help');
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
  my @args = @_;
  my %opt;
  local @ARGV = @args;
  Getopt::Long::GetOptions(\%opt, 'help');
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