use strict;
use warnings;
use Path::Tiny;
use lib 't/lib';
use Test::More;
use App::Raider::Hall;
use JSON::MaybeXS ();
use IO::Async::Loop;
use File::Temp qw( tempdir );

use App::Raider;  # for pack discovery path

subtest 'Hall new + config' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  my $hall = App::Raider::Hall->new(root => path($tmp));

  isa_ok($hall, 'App::Raider::Hall');
  is($hall->root->stringify, $tmp, 'root set');
  ok(!exists($hall->config->{raiders}), 'empty config when no yml');
};

subtest 'Hall with config file' => sub {
  my $tmp = tempdir(CLEANUP => 1);

  path("$tmp/.raider-hall.yml")->spew_utf8(YAML::PP->new->dump({
    longhouse => 0,
    raiders => {
      Bjorn => {
        engine => 'anthropic',
        persona => 'caveman',
        packs => [],
        mcp => [],
        isolated => 0,
      },
    },
  }));

  my $hall = App::Raider::Hall->new(root => path($tmp));
  is($hall->config->{raiders}{Bjorn}{engine}, 'anthropic', 'config loaded');
  is($hall->config->{longhouse}, 0, 'longhouse false');
};

subtest 'ps returns empty initially' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  my $hall = App::Raider::Hall->new(root => path($tmp));

  my @list = $hall->ps;
  is_deeply(\@list, [], 'ps empty');
};

subtest 'kill returns error for unknown id' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  my $hall = App::Raider::Hall->new(root => path($tmp));

  my $result = $hall->kill_raider('nonexistent');
  ok($result->{error}, 'kill returns error');
};

subtest 'attach returns error for unknown id' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  my $hall = App::Raider::Hall->new(root => path($tmp));

  my $result = $hall->attach('nonexistent');
  ok($result->{error}, 'attach returns error');
};

subtest 'logs returns error for unknown id' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  my $hall = App::Raider::Hall->new(root => path($tmp));

  my $result = $hall->logs(id => 'nonexistent');
  ok($result->{error}, 'logs returns error');
};

subtest '1name singleton parsing' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  my $hall = App::Raider::Hall->new(root => path($tmp));

  my ($slot, $base) = $hall->_parse_name('1bjorn');
  is($slot, '1bjorn', 'slot is 1bjorn');
  is($base, 'bjorn', 'base is bjorn');

  my ($slot2, $base2) = $hall->_parse_name('bjorn');
  ok(!defined($slot2), 'no slot for plain name');
  is($base2, 'bjorn', 'base is bjorn');
};

subtest 'state_dir is created' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  my $hall = App::Raider::Hall->new(root => path($tmp));

  my $sd = $hall->state_dir;
  ok(-d $sd, 'state_dir created');
  like($sd->stringify, qr/\.raider-hall\/state$/, 'state dir path correct');
};

subtest 'longhouse_lib_path' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  my $hall = App::Raider::Hall->new(root => path($tmp));

  my $lp = $hall->longhouse_lib_path;
  like($lp->stringify, qr/longhouse\/lib$/, 'longhouse lib path');
};

subtest 'spawn result structure' => sub {
  my $tmp = tempdir(CLEANUP => 1);

  path("$tmp/.raider-hall.yml")->spew_utf8(YAML::PP->new->dump({
    raiders => {
      TestR => {
        engine => 'shell',
        persona => 'caveman',
        packs => [],
        mcp => [],
        isolated => 0,
      },
    },
  }));

  my $hall = App::Raider::Hall->new(root => path($tmp));

  # Use a simple shell command so we don't actually make API calls
  my $result = $hall->spawn(name => 'TestR', mission => 'echo hello');
  ok($result->{id}, 'spawn returned id');
  ok($result->{pid}, 'spawn returned pid');
  ok($result->{slot}, 'spawn returned slot');
};

done_testing;