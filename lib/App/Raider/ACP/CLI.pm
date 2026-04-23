package App::Raider::ACP::CLI;
our $VERSION = '0.004';
# ABSTRACT: raider acp subcommand dispatcher (client side)

use strict;
use warnings;
use Getopt::Long qw( GetOptions );
use JSON::MaybeXS ();
use Term::ANSIColor qw( colored );
use App::Raider::ACP::Client;

=head1 SYNOPSIS

    raider acp ping  HOST:PORT
    raider acp prompt HOST:PORT "list files"
    raider acp connect HOST:PORT [--raider bjorn]

=cut

sub _parse_endpoint {
  my ($ep) = @_;
  die "endpoint required (HOST:PORT)\n" unless $ep;
  my ($host, $port) = $ep =~ /^(.*):(\d+)$/
    ? ($1, $2)
    : ('127.0.0.1', $ep =~ /^\d+$/ ? $ep : die "bad endpoint '$ep' (want HOST:PORT or PORT)\n");
  return ($host, $port);
}

sub _color_on  { -t STDOUT ? colored([$_[0]], $_[1]) : $_[1] }

sub main {
  my ($class, @args) = @_;

  if (!@args || $args[0] eq '--help' || $args[0] eq '-h') {
    print usage();
    exit 0;
  }

  my $cmd = shift @args;
  if ($cmd eq 'ping')    { return run_ping(@args); }
  if ($cmd eq 'prompt')  { return run_prompt(@args); }
  if ($cmd eq 'connect') { return run_connect(@args); }
  if ($cmd eq 'help')    { print usage(); exit 0; }
  die "Unknown subcommand: $cmd\n\n" . usage();
}

sub usage {
  return <<"EOF";
Usage: raider acp <subcommand> HOST:PORT [options]

Subcommands:
  ping HOST:PORT              Handshake only — print the server's
                              protocolVersion and agentCapabilities.
  prompt HOST:PORT TEXT...    One-shot: open a session, send TEXT,
                              print streaming updates, exit on stopReason.
  connect HOST:PORT           Open an interactive ACP session as a REPL.

Options (prompt/connect):
  --raider NAME   Target raider slot on the remote hall.
  --json          Print raw JSON-RPC frames to stderr as they arrive.

See raider hall start --acp-port N for the server side.
EOF
}

sub run_ping {
  my @args = @_;
  my $ep = shift @args or die "Usage: raider acp ping HOST:PORT\n";
  my ($host, $port) = _parse_endpoint($ep);

  my $c = App::Raider::ACP::Client->new(host => $host, port => $port);
  my $res = $c->initialize;
  my $json = JSON::MaybeXS->new(pretty => 1, canonical => 1);
  print $json->encode($res);
  return 0;
}

sub run_prompt {
  my @args = @_;
  my %opt;
  local @ARGV = @args;
  Getopt::Long::GetOptions(\%opt, 'raider=s', 'json', 'help');
  return print_prompt_help() if $opt{help};

  my $ep = shift @ARGV or die "Usage: raider acp prompt HOST:PORT TEXT...\n";
  my ($host, $port) = _parse_endpoint($ep);
  my $text = join ' ', @ARGV;
  die "No prompt text given.\n" unless length $text;

  my $c = App::Raider::ACP::Client->new(host => $host, port => $port);
  $c->initialize;
  my $sess = $c->new_session($opt{raider} ? { raiderName => $opt{raider} } : {});

  my $result = $c->prompt_stream($sess->{sessionId}, $text, sub {
    my ($params) = @_;
    _print_update($params, $opt{json});
  });

  print "\n";
  print "-- stopReason: " . ($result->{stopReason} // '(none)') . "\n";
  return 0;
}

sub print_prompt_help {
  print <<"EOF";
raider acp prompt HOST:PORT TEXT... [--raider NAME] [--json]

One-shot ACP prompt. Connects, opens a session, sends TEXT, prints
incoming session/update notifications, exits on the final stopReason.
EOF
  exit 0;
}

sub run_connect {
  my @args = @_;
  my %opt;
  local @ARGV = @args;
  Getopt::Long::GetOptions(\%opt, 'raider=s', 'json', 'help');
  return print_connect_help() if $opt{help};

  my $ep = shift @ARGV or die "Usage: raider acp connect HOST:PORT\n";
  my ($host, $port) = _parse_endpoint($ep);

  my $c = App::Raider::ACP::Client->new(host => $host, port => $port);
  my $init = $c->initialize;
  print _color_on('bright_blue', "connected to $host:$port\n");
  print _color_on('bright_black',
    "protocol v$init->{protocolVersion}"
    . ($opt{raider} ? " — raider: $opt{raider}" : '')
    . "\n\n");

  my $sess = $c->new_session($opt{raider} ? { raiderName => $opt{raider} } : {});
  my $sid = $sess->{sessionId};

  # Read loop: use Term::ReadLine if available, else bare STDIN.
  require Term::ReadLine;
  my $term = Term::ReadLine->new('raider-acp');
  eval { $term->ornaments(0) };
  my $prompt = _color_on('bright_black', "acp> ");

  while (defined(my $line = $term->readline($prompt))) {
    $line =~ s/^\s+|\s+$//g;
    next unless length $line;
    last if $line =~ m{^(?:/quit|/exit|:q|quit|exit)$}i;

    if ($line =~ m{^/cancel$}) {
      eval { $c->cancel($sid) };
      print _color_on(yellow => "[cancel sent]\n");
      next;
    }

    my $result = eval {
      $c->prompt_stream($sid, $line, sub {
        my ($params) = @_;
        _print_update($params, $opt{json});
      });
    };
    if ($@) {
      my $err = $@; chomp $err;
      print _color_on(red => "error: $err\n");
      next;
    }
    print "\n";
    print _color_on('bright_black',
      "-- stopReason: " . ($result->{stopReason} // '(none)') . "\n");
  }

  print _color_on('bright_black', "bye.\n");
  return 0;
}

sub print_connect_help {
  print <<"EOF";
raider acp connect HOST:PORT [--raider NAME] [--json]

Open an interactive REPL backed by a remote ACP agent. Each input line
is sent as a session/prompt; session/update notifications stream to
the terminal. /cancel sends session/cancel; /quit exits.
EOF
  exit 0;
}

sub _print_update {
  my ($params, $raw_json) = @_;
  if ($raw_json) {
    my $j = JSON::MaybeXS->new(canonical => 1);
    print STDERR $j->encode($params) . "\n";
  }
  my $u = $params->{update} or return;
  # agent_message_chunk { content: { type: text, text: ... } }
  my $content = $u->{content};
  if (ref $content eq 'HASH' && defined $content->{text}) {
    print $content->{text};
    *STDOUT->flush if *STDOUT->can('flush');
  }
}

1;

__END__

=head1 SEE ALSO

L<App::Raider::ACP::Client>, L<App::Raider::Hall::ACP>.

=cut
