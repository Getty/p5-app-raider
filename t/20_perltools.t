#!/usr/bin/env perl
# ABSTRACT: Unit tests for the PerlTools MCP server

use strict;
use warnings;
use Test2::Bundle::More;
use File::Temp qw( tempdir );
use Path::Tiny;
use JSON::MaybeXS ();

use App::Raider::PerlTools qw( build_perl_tools_server );

my $dir = tempdir(CLEANUP => 1);

my $server = build_perl_tools_server(root => $dir);

sub call_tool {
  my ($name, $args) = @_;
  my ($tool) = grep { $_->name eq $name } @{ $server->tools };
  die "no tool $name" unless $tool;
  return $tool->code->($tool, $args);
}

sub decoded {
  my ($res) = @_;
  my $text = $res->{content}[0]{text};
  return JSON::MaybeXS::decode_json($text);
}

subtest perl_eval_basic => sub {
  my $res = call_tool('perl_eval', { code => 'print "hello world"' });
  ok(!$res->{isError}, 'no error');
  my $d = decoded($res);
  like($d->{stdout}, qr/hello world/, 'stdout captured');
  is($d->{exit_code}, 0, 'exit code 0');
};

subtest perl_eval_stderr => sub {
  my $res = call_tool('perl_eval', { code => 'warn "test warning"' });
  my $d = decoded($res);
  like($d->{stderr}, qr/test warning/, 'stderr captured');
};

subtest perl_eval_return_value => sub {
  my $res = call_tool('perl_eval', { code => 'print "42"' });
  my $d = decoded($res);
  is($d->{return_value}, '42', 'return value from stdout');
};

subtest perl_eval_bad_code => sub {
  my $res = call_tool('perl_eval', { code => 'die "boom"' });
  my $d = decoded($res);
  ok($d->{exit_code} != 0, 'non-zero exit code');
  like($d->{stderr}, qr/boom/, 'stderr captured');
};

subtest perl_eval_stdin => sub {
  my $res = call_tool('perl_eval', {
    code    => 'my $x = <STDIN>; print uc $x',
    stdin   => "hello\n",
    timeout => 5,
  });
  my $d = decoded($res);
  like($d->{stdout}, qr/HELLO/, 'stdin processed');
};

subtest perl_check_valid => sub {
  my $res = call_tool('perl_check', { code => 'print "valid"' });
  ok(!$res->{isError}, 'no error');
  my $d = decoded($res);
  is($d->{valid}, JSON::MaybeXS::true, 'valid syntax');
  ok(!defined $d->{syntax_error}, 'no syntax error');
};

subtest perl_check_invalid => sub {
  my $res = call_tool('perl_check', { code => 'use strict; my @a = (1, 2' });
  ok(!$res->{isError}, 'tool call itself succeeded');
  my $d = decoded($res);
  is($d->{valid}, JSON::MaybeXS::false, 'invalid syntax');
  ok(defined $d->{syntax_error}, 'syntax_error populated');
};

subtest perl_cpanm_init_lib => sub {
  my $target = path($dir)->child('.raider', 'lib')->stringify;

  my $res = call_tool('perl_cpanm', {
    module  => 'Acme::Test::Raider',
    options => { target => $target },
  });

  ok(-d $target, 'lib directory created');
  ok(-f path($target, 'cpanfile'), 'cpanfile created');
  ok(-f path($target, 'perl-version'), 'perl-version created');
};

subtest perl_cpanm_idempotent => sub {
  my $target = path($dir)->child('.raider', 'lib2')->stringify;

  call_tool('perl_cpanm', {
    module  => 'Acme::Double',
    options => { target => $target },
  });
  call_tool('perl_cpanm', {
    module  => 'Acme::Double',
    options => { target => $target },
  });

  my $cpanfile = path($target, 'cpanfile')->slurp_utf8;
  my $count = () = $cpanfile =~ /\bAcme::Double\b/g;
  is($count, 1, 'cpanfile entry is idempotent (no duplicates)');
};

done_testing;