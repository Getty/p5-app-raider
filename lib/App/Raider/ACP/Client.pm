package App::Raider::ACP::Client;
our $VERSION = '0.004';
# ABSTRACT: Minimal synchronous ACP client over TCP

use strict;
use warnings;
use IO::Socket::IP;
use JSON::MaybeXS;
use Cwd ();

=head1 SYNOPSIS

    use App::Raider::ACP::Client;
    my $c = App::Raider::ACP::Client->new(host => '127.0.0.1', port => 38421);
    my $init = $c->initialize;
    my $s    = $c->new_session;
    $c->prompt_stream($s->{sessionId}, "summarise Changes", sub {
        my ($update) = @_;
        # $update is the params of a session/update JSON-RPC notification
        print $update->{update}{content}{text} // '';
    });

=head1 DESCRIPTION

Line-framed JSON-RPC 2.0 over a blocking TCP socket. Matched against
L<App::Raider::Hall::ACP> on the server side, but protocol-clean so it
speaks to any conforming ACP agent.

Sync by design: this is a CLI client, not a daemon. The one non-trivial
piece is C<prompt_stream>, which multiplexes inbound C<session/update>
notifications with the pending C<session/prompt> response on the same
socket.

=method new(host => STR, port => INT, [timeout => SECS])

Open a connection. Dies on failure.

=method initialize

Handshake. Returns the server's C<result> hash
(C<protocolVersion>, C<agentCapabilities>).

=method new_session(\%params)

Create a session. Adds the current C<cwd> automatically if the caller
didn't set one. Returns the C<result> hash (C<sessionId>, ...).

=method prompt_stream($session_id, $text, $on_update)

Send a prompt, invoke C<$on_update-E<gt>($params)> for each
C<session/update> notification that arrives, and return the final
result hash (typically C<{ stopReason =E<gt> ... }>).

=method cancel($session_id)

Send C<session/cancel>. Returns the server's result.

=cut

sub new {
  my ($class, %args) = @_;
  my $sock = IO::Socket::IP->new(
    PeerHost => $args{host} // '127.0.0.1',
    PeerPort => $args{port} // die "port required",
    Timeout  => $args{timeout} // 10,
  ) or die "Cannot connect to $args{host}:$args{port}: $!";
  $sock->autoflush(1);
  bless {
    sock    => $sock,
    next_id => 1,
    buf     => '',
    json    => JSON::MaybeXS->new,
    host    => $args{host},
    port    => $args{port},
  }, $class;
}

sub _send {
  my ($self, $msg) = @_;
  my $bytes = $self->{json}->encode($msg) . "\n";
  my $n = syswrite $self->{sock}, $bytes;
  die "write to ACP server failed: $!" unless defined $n;
}

sub _read_line {
  my ($self) = @_;
  while ($self->{buf} !~ /\n/) {
    my $chunk;
    my $n = sysread $self->{sock}, $chunk, 4096;
    return undef unless defined $n && $n > 0;
    $self->{buf} .= $chunk;
  }
  $self->{buf} =~ s/^(.*?)\n//;
  my $line = $1;
  $line =~ s/\r$//;
  return $line;
}

sub _call {
  my ($self, $method, $params) = @_;
  my $id = $self->{next_id}++;
  $self->_send({
    jsonrpc => '2.0', id => $id, method => $method, params => $params // {},
  });
  while (defined(my $line = $self->_read_line)) {
    next unless length $line;
    my $msg = eval { $self->{json}->decode($line) } // next;
    if (defined $msg->{id} && $msg->{id} eq $id) {
      die "ACP error: $msg->{error}{message}\n" if $msg->{error};
      return $msg->{result};
    }
    # Any other frame (a notification or a response to a different id)
    # gets swallowed in pure-call mode. prompt_stream handles this
    # properly.
  }
  die "ACP connection closed while waiting for reply to $method\n";
}

sub initialize {
  my ($self) = @_;
  $self->_call('initialize', {});
}

sub new_session {
  my ($self, $extra) = @_;
  my %p = (cwd => Cwd::cwd(), %{ $extra // {} });
  $self->_call('session/new', \%p);
}

sub cancel {
  my ($self, $sid) = @_;
  $self->_call('session/cancel', { sessionId => $sid });
}

sub prompt_stream {
  my ($self, $sid, $text, $on_update) = @_;
  my $id = $self->{next_id}++;
  $self->_send({
    jsonrpc => '2.0', id => $id, method => 'session/prompt',
    params => {
      sessionId => $sid,
      prompt    => [{ type => 'text', text => $text }],
    },
  });
  while (defined(my $line = $self->_read_line)) {
    next unless length $line;
    my $msg = eval { $self->{json}->decode($line) } // next;
    if (defined $msg->{id} && $msg->{id} eq $id) {
      die "ACP error: $msg->{error}{message}\n" if $msg->{error};
      return $msg->{result};
    }
    if (($msg->{method} // '') eq 'session/update' && $on_update) {
      $on_update->($msg->{params});
    }
  }
  die "ACP connection closed during session/prompt\n";
}

sub close {
  my ($self) = @_;
  close $self->{sock} if $self->{sock};
  delete $self->{sock};
}

sub DESTROY { $_[0]->close }

1;

__END__

=head1 SEE ALSO

L<App::Raider::Hall::ACP>, L<App::Raider::ACP::CLI>.

=cut
