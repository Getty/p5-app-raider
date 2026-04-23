package App::Raider::PerlTools;
our $VERSION = '0.004';
# ABSTRACT: MCP::Server factory with Perl evaluation, syntax check, and module install

use strict;
use warnings;
use Path::Tiny;
use MCP::Server;
use IPC::Run qw( start timeout );
use JSON::MaybeXS ();

use Exporter 'import';
our @EXPORT_OK = qw( build_perl_tools_server );

=func build_perl_tools_server

    my $server = App::Raider::PerlTools::build_perl_tools_server(
        root       => '/some/dir',  # chroot root (required)
        lib_target => '.raider/lib',  # optional override
    );

Returns an L<MCP::Server> instance with the tools C<perl_eval>, C<perl_check>,
and C<perl_cpanm> registered.

=cut

sub build_perl_tools_server {
  my %args = @_;
  my $root       = path($args{root} // '.')->absolute;
  my $lib_target_override = $args{lib_target};

  my $resolve_lib_target = sub {
    return $lib_target_override if defined $lib_target_override;
    return path($root)->child('.raider', 'lib')->stringify;
  };

  my $ensure_lib_init = sub {
    my ($target) = @_;
    my $dir = path($target);
    return if -d $dir && -f $dir->child('cpanfile');

    $dir->mkpath;
    $dir->child('perl-version')->spew_utf8("$]\n");
    $dir->child('cpanfile')->spew_utf8(";\n");
    return;
  };

  my $append_to_cpanfile = sub {
    my ($target, $module) = @_;
    my $cpanfile = path($target)->child('cpanfile');
    my $content = $cpanfile->slurp_utf8;
    return if $content =~ /\b\Q$module\E\b/m;
    $cpanfile->append_utf8("requires '$module';\n");
    return;
  };

  # --- Tool: perl_eval ---

  my $server = MCP::Server->new(name => 'app-raider-perl', version => '1.0');

  $server->tool(
    name        => 'perl_eval',
    description => 'Evaluate a snippet of Perl code and return stdout, stderr, exit code, and return value. No persistent session — each call starts fresh. On missing-module error: auto-installs once and retries.',
    input_schema => {
      type       => 'object',
      properties => {
        code    => { type => 'string', description => 'Perl code to eval (as one-liner or block)' },
        stdin   => { type => 'string', description => 'String to feed to STDIN (optional)' },
        timeout => { type => 'integer', description => 'Max seconds before kill (default: 60)', default => 60 },
      },
      required => ['code'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $code   = $in->{code}    // '';
      my $stdin  = $in->{stdin}  // '';
      my $to_sec = $in->{timeout} // 60;

      my ($out, $err, $auto_installed);

      my $do_run = sub {
        my @cmd = ('perl', '-e', $code);
        my $h = start \@cmd, \$stdin, \$out, \$err, timeout($to_sec);
        $h->finish;
        my $fr = $h->full_result;
        return defined($fr) ? ($fr >> 8) : -1;
      };

      my ($rc, $timed_out);
      my $ok = eval {
        $rc = $do_run->();
        1;
      };

      unless ($ok) {
        $rc = -1;
        $timed_out = 1;
        $err //= '';
        chomp $err;
      }

      # Auto-recover: check for "Can't locate X/Y.pm" once
      my @missing;
      if ($err && $err =~ /^Can't locate (\S+\.pm)/m) {
        my $mod = $1;
        $mod =~ s{/}{::}g;
        $mod =~ s{\.pm$}{};
        push @missing, $mod;
      }

      if (@missing && !$auto_installed && !$timed_out) {
        my ($i_out, $i_err);
        my $ih = start ['cpanm', @missing], \$!, \$i_out, \$i_err, timeout(300);
        $ih->finish;
        my $i_rc = $? >> 8;

        if ($i_rc == 0) {
          $auto_installed = \@missing;
          $rc = $do_run->();
        }
        else {
          $err .= "\n[auto-install failed for @missing: $i_err]";
        }
      }

      my $return_value;
      if (defined $out && length $out) {
        chomp(my @lines = split /\n/, $out);
        $return_value = $lines[-1] if @lines;
      }

      my %result = (
        stdout       => $out // '',
        stderr       => $err // '',
        return_value => $return_value,
        exit_code    => $rc // 0,
      );
      $result{auto_installed} = $auto_installed if $auto_installed;
      $result{error} = 'timeout' if $timed_out;

      return $tool->structured_result(\%result);
    },
  );

  # --- Tool: perl_check ---

  $server->tool(
    name        => 'perl_check',
    description => 'Check Perl syntax without executing the code. Runs "perl -c".',
    input_schema => {
      type       => 'object',
      properties => {
        code => { type => 'string', description => 'Perl code to syntax-check' },
      },
      required => ['code'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $code = $in->{code} // '';

      my ($out, $err);
      my $h = start ['perl', '-c', '-'], \$code, \$out, \$err, timeout(30);
      $h->finish;
      my $fr = $h->full_result;
      my $rc = defined($fr) ? ($fr >> 8) : -1;

      my $valid = ($rc == 0) ? JSON::MaybeXS::true() : JSON::MaybeXS::false();
      my $syntax_error;
      if ($rc != 0 && $err) {
        $syntax_error = $err;
        chomp $syntax_error;
      }

      return $tool->structured_result({
        valid        => $valid,
        syntax_error => $syntax_error // undef,
      });
    },
  );

  # --- Tool: perl_cpanm ---

  $server->tool(
    name        => 'perl_cpanm',
    description => 'Install a CPAN module into a private local::lib. Target auto-detected: explicit arg > preferred_lib_target from config > .raider/lib/standalone. Creates the target directory (with cpanfile + perl-version marker) on first install.',
    input_schema => {
      type       => 'object',
      properties => {
        module  => { type => 'string', description => 'Module name (or distribution) to install' },
        options => {
          type       => 'object',
          description => 'Installation options',
          properties => {
            test   => { type => 'boolean', description => 'Run tests before install (default: false)' },
            force  => { type => 'boolean', description => 'Force install (ignore errors)' },
            from   => { type => 'string',  description => 'CPAN mirror URL or path' },
            target => { type => 'string',  description => 'Override lib target directory' },
          },
        },
      },
      required => ['module'],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $module = $in->{module}  // '';
      my $opts   = $in->{options} // {};
      my $explicit_target = $opts->{target} // undef;

      my $target_dir = defined $explicit_target
        ? $explicit_target
        : $resolve_lib_target->();

      $ensure_lib_init->($target_dir);

      my @cmd = ('cpanm', '--local-lib', $target_dir);
      push @cmd, '--test'    if $opts->{test};
      push @cmd, '--force'   if $opts->{force};
      push @cmd, '--from', $opts->{from} if $opts->{from};
      push @cmd, $module;

      my ($out, $err);
      my $h = start \@cmd, \$!, \$out, \$err, timeout(300);
      $h->finish;
      my $fr = $h->full_result;
      my $rc = defined($fr) ? ($fr >> 8) : -1;

      $append_to_cpanfile->($target_dir, $module);

      my $installed = ($rc == 0) ? JSON::MaybeXS::true() : JSON::MaybeXS::false();

      return $tool->structured_result({
        installed => $installed,
        target    => $target_dir,
        version   => undef,
        stdout    => $out // '',
        stderr    => $err // '',
      });
    },
  );

  return $server;
}

1;

=head1 TOOLS

=head2 perl_eval

Evaluate Perl code. Returns stdout, stderr, exit_code, return_value, and
(optionally) auto_installed.

On "Can't locate X/Y.pm" in stderr, auto-installs the module once then
retries the eval. If retry still fails, returns the error.

=head2 perl_check

Syntax-check Perl code via C<perl -c>. Returns C<valid> (bool) and
C<syntax_error> (string or null).

=head2 perl_cpanm

Install a CPAN module into a private local::lib. Creates the target
directory (with cpanfile + perl-version marker) on first install. The
cpanfile is updated idempotently (no duplicate entries).

=cut