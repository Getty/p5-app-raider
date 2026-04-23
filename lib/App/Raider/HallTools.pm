package App::Raider::HallTools;
our $VERSION = '0.004';
# ABSTRACT: MCP::Server factory with hall-side tools (telegram_reply, hall_status)

use strict;
use warnings;
use MCP::Server;
use IO::Socket::UNIX;
use JSON::MaybeXS ();

use Exporter 'import';
our @EXPORT_OK = qw( build_hall_tools_server );

=func build_hall_tools_server

    my $server = App::Raider::HallTools::build_hall_tools_server(
        socket => $ENV{RAIDER_HALL_SOCKET},
    );

Returns an L<MCP::Server> exposing tools that let a raider running inside
a hall talk back to its hall daemon:

=over

=item * C<telegram_reply(bot, chat_id, text)>

=item * C<hall_status()>

=item * C<hall_spawn(name, mission)>

=back

Each tool opens a short-lived UNIX-socket command connection to the
hall, sends a single JSON frame, reads the reply, and returns it as
text. Errors surface as text_result with isError=1.

=cut

sub _call {
  my ($sock_path, $cmd, %payload) = @_;

  my $s = IO::Socket::UNIX->new(Peer => $sock_path)
    or return { error => "cannot connect to hall socket $sock_path: $!" };
  $s->autoflush(1);

  my $frame = JSON::MaybeXS->new->encode({
    type => 'command',
    payload => { cmd => $cmd, %payload },
  });
  print $s "$frame\n";

  my $line = <$s>;
  close $s;
  return { error => 'no response from hall' } unless defined $line;
  chomp $line;
  my $resp = eval { JSON::MaybeXS->new->decode($line) };
  return { error => "invalid hall response: $@" } if $@;
  return $resp;
}

sub build_hall_tools_server {
  my (%args) = @_;
  my $sock = $args{socket}
    or die "build_hall_tools_server: socket param required";

  my $server = MCP::Server->new(name => 'app-raider-hall', version => '1.0');

  $server->tool(
    name         => 'telegram_reply',
    description  => 'Send a Telegram message from the hall. Use this to reply to a user that reached you through the hall\'s telegram.in event.',
    input_schema => {
      type       => 'object',
      properties => {
        bot     => { type => 'string',  description => 'Bot name as configured in .raider-hall.yml' },
        chat_id => { type => 'integer', description => 'Telegram chat id' },
        text    => { type => 'string',  description => 'Message body (Markdown)' },
      },
      required => [qw(bot chat_id text)],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $r = _call($sock, 'telegram_reply',
        bot => $in->{bot}, chat_id => $in->{chat_id}, text => $in->{text});
      return $tool->text_result("Error: $r->{error}", 1) if $r->{error};
      return $tool->text_result('sent');
    },
  );

  $server->tool(
    name         => 'hall_status',
    description  => 'Ask the hall how many raiders are currently running.',
    input_schema => { type => 'object', properties => {} },
    code => sub {
      my ($tool, $in) = @_;
      my $r = _call($sock, 'status');
      return $tool->text_result("Error: $r->{error}", 1) if $r->{error};
      return $tool->text_result(JSON::MaybeXS->new(canonical => 1)->encode($r));
    },
  );

  $server->tool(
    name         => 'hall_spawn',
    description  => 'Spawn another raider in the same hall (respects 1name singleton queueing).',
    input_schema => {
      type       => 'object',
      properties => {
        name    => { type => 'string', description => 'Raider slot name (e.g. "bjorn" or "1bjorn")' },
        mission => { type => 'string', description => 'One-shot task' },
      },
      required => [qw(name mission)],
    },
    code => sub {
      my ($tool, $in) = @_;
      my $r = _call($sock, 'spawn', name => $in->{name}, mission => $in->{mission});
      return $tool->text_result("Error: $r->{error}", 1) if $r->{error};
      return $tool->text_result(JSON::MaybeXS->new(canonical => 1)->encode($r));
    },
  );

  return $server;
}

1;

__END__

=head1 SEE ALSO

=over

=item * L<App::Raider::Hall>

=item * L<MCP::Server>

=back

=cut
