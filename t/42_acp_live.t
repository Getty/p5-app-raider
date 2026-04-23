use strict;
use warnings;
use Test::More;
use Path::Tiny;
use File::Temp qw( tempdir );
use IO::Socket::IP;
use YAML::PP;
use POSIX qw( WNOHANG );

# End-to-end LIVE test: spins a real hall with ACP, sends a real
# session/prompt, expects a real LLM answer to come back. Skipped
# unless OPENAI_API_KEY is set — CI keeps it off by default, local
# runs can opt in.

plan skip_all => 'OPENAI_API_KEY not set (live test disabled)'
  unless $ENV{OPENAI_API_KEY};

# Pick a free port.
my $probe = IO::Socket::IP->new(
  LocalHost => '127.0.0.1', LocalPort => 0, Listen => 1, ReuseAddr => 1,
) or die "cannot probe: $!";
my $port = $probe->sockport;
close $probe;

# Locate our dev raider binary so the hall spawns the in-tree one, not
# whatever is on $PATH from a previous install. cwd during `prove -l`
# is the distribution root.
my $repo = Path::Tiny::path('.')->absolute;
my $raider_bin = $repo->child('bin', 'raider');
die "bin/raider not executable: $raider_bin" unless -x $raider_bin;
$ENV{RAIDER_HALL_RAIDER_BIN} = $raider_bin->stringify;

# Make sure the spawned raider finds App::Raider from the tree too.
$ENV{PERL5LIB} = join ':', grep { defined && length }
  ($repo->child('lib')->stringify, $ENV{PERL5LIB});

my $tmp = tempdir(CLEANUP => 1);
path("$tmp/.raider-hall.yml")->spew_utf8(YAML::PP->new->dump_string({
  raiders => {
    Oli => {
      engine => 'openai',
      model  => 'gpt-4o-mini',
      persona => 'caveman',
      packs => [],
      mcp => [],
      isolated => 0,
    },
  },
  acp => { port => $port, host => '127.0.0.1' },
}));

my $pid = fork();
die "fork: $!" unless defined $pid;

if ($pid == 0) {
  require App::Raider::Hall;
  my $hall = App::Raider::Hall->new(root => path($tmp));
  $SIG{TERM} = sub { $hall->shutdown };
  eval { $hall->run };
  exit 0;
}

# Wait for the listener.
my $deadline = time + 5;
my $up;
while (time < $deadline) {
  $up = IO::Socket::IP->new(PeerHost => '127.0.0.1', PeerPort => $port, Timeout => 1);
  last if $up;
  select undef, undef, undef, 0.1;
}
ok($up, "hall ACP up on $port") or do {
  kill 'TERM', $pid; waitpid $pid, 0; done_testing; exit 1;
};
close $up;

require App::Raider::ACP::Client;
my $c = App::Raider::ACP::Client->new(host => '127.0.0.1', port => $port);

my $init = $c->initialize;
ok($init->{protocolVersion}, 'initialize');

my $sess = $c->new_session;
like($sess->{sessionId}, qr/^acp-/, 'session created');

my @chunks;
my $result = eval {
  $c->prompt_stream(
    $sess->{sessionId},
    'say hi in exactly three words',
    sub {
      my ($params) = @_;
      my $text = $params->{update}{content}{text};
      push @chunks, $text if defined $text && length $text;
    },
  );
};
my $err = $@;

ok(!$err, "prompt_stream returned without dying")
  or diag "error: $err";
ok($result, 'got a final result');
ok(scalar @chunks, 'received at least one session/update chunk')
  or diag "no streaming chunks at all";
is($result->{stopReason}, 'end_turn', 'stopReason is end_turn')
  or diag "got: " . (defined $result->{stopReason} ? $result->{stopReason} : '(undef)');

# Peek at what we captured — the prompt was deliberately tiny so the
# reply should fit on one line. Useful for eyeballing a local run.
diag "captured " . scalar(@chunks) . " chunk(s)";
diag "last chunk: $chunks[-1]" if @chunks;

$c->close;

kill 'TERM', $pid;
my $reaped;
for (1..60) {
  if (waitpid($pid, WNOHANG) > 0) { $reaped = 1; last }
  select undef, undef, undef, 0.2;
}
if (!$reaped) {
  kill 'KILL', $pid;
  waitpid $pid, 0;
}

done_testing;
