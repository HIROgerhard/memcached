# $Id$
#
# Copyright (c) 2003  Brad Fitzpatrick <brad@danga.com>
#
# See COPYRIGHT section in pod text below for usage and distribution rights.
#

package MemCachedClient;

use strict;
no strict 'refs';
use Storable ();
use Socket qw(MSG_NOSIGNAL PF_INET SOCK_STREAM);

# flag definitions
use constant F_STORABLE => 1;
use constant F_COMPRESS => 2;

# size savings required before saving compressed value
use constant COMPRESS_SAVINGS => 0.20; # percent

use vars qw($VERSION $HAVE_ZLIB);
$VERSION = "1.0.8-pre";

BEGIN {
    $HAVE_ZLIB = eval "use Compress::Zlib (); 1;";
}

my %host_dead;   # host -> unixtime marked dead until
my %cache_sock;  # host -> socket

my $PROTO_TCP;

sub new {
    my ($class, $args) = @_;
    my $self = {};
    bless $self, ref $class || $class;

    $self->set_servers($args->{'servers'});
    $self->{'debug'} = $args->{'debug'};
    $self->{'stats'} = {};
    $self->{'compress_threshold'} = $args->{'compress_threshold'};
    $self->{'compress_enable'}    = 1;

    return $self;
}

sub set_servers {
    my ($self, $list) = @_;
    $self->{'servers'} = $list || [];
    $self->{'active'} = scalar @{$self->{'servers'}};
    $self->{'buckets'} = undef;
    $self->{'bucketcount'} = 0;

    $self->{'_single_sock'} = undef;
    if (@{$self->{'servers'}} == 1) {
	$self->{'_single_sock'} = $self->{'servers'}[0];
    }

    return $self;
}

sub set_debug {
    my ($self, $dbg) = @_;
    $self->{'debug'} = $dbg;
}

sub set_compress_threshold {
    my ($self, $thresh) = @_;
    $self->{'compress_threshold'} = $thresh;
}

sub enable_compress {
    my ($self, $enable) = @_;
    $self->{'compress_enable'} = $enable;
}

sub forget_dead_hosts {
    %host_dead = ();
}

sub _dead_sock {
    my ($sock, $ret) = @_;
    if ($sock =~ /^Sock_(.+?):(\d+)$/) {
        my $now = time();
        my ($ip, $port) = ($1, $2);
        my $host = "$ip:$port";
        $host_dead{$host} = $host_dead{$ip} = $now + 30 + int(rand(10));
        delete $cache_sock{$host};
    }
    return $ret;  # 0 or undef, probably, depending on what caller wants
}

sub _close_sock {
    my ($sock) = @_;
    if ($sock =~ /^Sock_(.+?):(\d+)$/) {
        my ($ip, $port) = ($1, $2);
        my $host = "$ip:$port";
        close $sock;
        delete $cache_sock{$host};
    }
}

sub sock_to_host { # (host)
    my $host = $_[0];
    return $cache_sock{$host} if $cache_sock{$host};

    my $now = time();
    my ($ip, $port) = $host =~ /(.*):(\d+)/;
    return undef if 
         $host_dead{$host} && $host_dead{$host} > $now || 
         $host_dead{$ip} && $host_dead{$ip} > $now;

    my $sock = "Sock_$host";
    my $proto = $PROTO_TCP ||= getprotobyname('tcp');

    socket($sock, PF_INET, SOCK_STREAM, $proto);
    my $sin = Socket::sockaddr_in($port,Socket::inet_aton($ip));

    return _dead_sock($sock, undef) unless (connect($sock,$sin));

    # make the new socket not buffer writes.
    select($sock);
    $| = 1;
    select(STDOUT);

    return $cache_sock{$host} = $sock;
}

sub get_sock { # (key)
    my ($self, $key) = @_;
    return sock_to_host($self->{'_single_sock'}) if $self->{'_single_sock'};
    return undef unless $self->{'active'};
    my $hv = ref $key ? int($key->[0]) : _hashfunc($key);

    unless ($self->{'buckets'}) {
        my $bu = $self->{'buckets'} = [];
        foreach my $v (@{$self->{'servers'}}) {
            if (ref $v eq "ARRAY") {
                for (1..$v->[1]) { push @$bu, $v->[0]; }
            } else { 
                push @$bu, $v; 
            }
        }
        $self->{'bucketcount'} = scalar @{$self->{'buckets'}};
    }

    my $real_key = ref $key ? $key->[1] : $key;
    my $tries = 0;
    while ($tries++ < 20) {
        my $host = $self->{'buckets'}->[$hv % $self->{'bucketcount'}];
        my $sock = sock_to_host($host);
        return $sock if $sock;
        $hv += _hashfunc($tries . $real_key);  # stupid, but works
    }
    return undef;
}

sub disconnect_all {
    close($_) foreach (values %cache_sock);
    %cache_sock = ();
}

sub delete {
    my ($self, $key, $time) = @_;
    return 0 unless $self->{'active'};
    my $sock = $self->get_sock($key);
    return 0 unless $sock;
    $self->{'stats'}->{"delete"}++;
    $key = ref $key ? $key->[1] : $key;
    $time = $time ? " $time" : "";
    my $cmd = "delete $key$time\r\n";
    send($sock, $cmd, MSG_NOSIGNAL) or return _dead_sock($sock, 0);
    my $res = readline($sock);
    return $res eq "DELETED\r\n";
}

sub add {
    _set("add", @_);
}

sub replace {
    _set("replace", @_);
}

sub set {
    _set("set", @_);
}

sub _set {
    my ($cmdname, $self, $key, $val, $exptime) = @_;
    return 0 unless $self->{'active'};
    my $sock = $self->get_sock($key);
    return 0 unless $sock;

    use bytes; # return bytes from length()

    $self->{'stats'}->{$cmdname}++;
    my $flags = 0;
    $key = ref $key ? $key->[1] : $key;

    if (ref $val) {
        $val = Storable::freeze($val);
        $flags |= F_STORABLE;
    }

    my $len = length($val);

    if ($self->{'compress_threshold'} && $HAVE_ZLIB && $self->{'compress_enable'} &&
        $len >= $self->{'compress_threshold'}) {

        my $c_val = Compress::Zlib::memGzip($val);
        my $c_len = length($c_val);

        # do we want to keep it?
        if ($c_len < $len*(1 - COMPRESS_SAVINGS)) {
            $val = $c_val;
            $len = $c_len;
            $flags |= F_COMPRESS;
        }
    }

    $exptime = int($exptime || 0);
    send($sock, "$cmdname $key $flags $exptime $len\r\n$val\r\n", MSG_NOSIGNAL)
        or return _dead_sock($sock, 0);

    my $line = readline($sock);
    if ($line eq "STORED\r\n") {
        print STDERR "MemCache: $cmdname $key = $val (STORED)\n" if $self->{'debug'};
        return 1;
    }
    if ($self->{'debug'}) {
        chop $line; chop $line;
        print STDERR "MemCache: $cmdname $key = $val ($line)\n";
    }
    return 0;
}

sub incr {
    _incrdecr("incr", @_);
}

sub decr {
    _incrdecr("decr", @_);
}

sub _incrdecr {
    my ($cmdname, $self, $key, $value) = @_;
    return undef unless $self->{'active'};
    my $sock = $self->get_sock($key);
    return undef unless $sock;
    $self->{'stats'}->{$cmdname}++;
    $value = 1 unless defined $value;
    send($sock, "$cmdname $key $value\r\n", MSG_NOSIGNAL)
	or return _dead_sock($sock, undef);
    my $line = readline($sock);
    return undef unless $line =~ /^(\d)/; 
    return $1;
}

sub get {
    my ($self, $key) = @_;
    $self->{'stats'}->{"get"}++;
    
    my $sock = $self->get_sock($key);
    return undef unless $sock;

    # get at the real key (we don't need the explicit hash value anymore)
    $key = $key->[1] if ref $key;

    my %val;
    send($sock, "get $key\r\n", MSG_NOSIGNAL) or return _dead_sock($sock, undef);
    _load_items($sock, \%val);

    if ($self->{'debug'}) {
        while (my ($k, $v) = each %val) {
            print STDERR "MemCache: got $k = $v\n";
        }
    }
    return $val{$key};
}

sub get_multi {
    my $self = shift;
    return undef unless $self->{'active'};
    $self->{'stats'}->{"get_multi"}++;
    my %val;        # what we'll be returning a reference to (realkey -> value)
    my %sock_keys;  # sockref_as_scalar -> [ realkeys ]
    my @socks;      # unique socket refs
    foreach my $key (@_) {
        my $sock = $self->get_sock($key);
        next unless $sock;
        $key = ref $key ? $key->[1] : $key;
        unless ($sock_keys{$sock}) {
            $sock_keys{$sock} = [];
            push @socks, $sock;
        }
        push @{$sock_keys{$sock}}, $key;
    }
    $self->{'stats'}->{"get_keys"} += @_;
    $self->{'stats'}->{"get_socks"} += @socks;

    # pass 1: send out requests
    my @gather;
    foreach my $sock (@socks) {
        if (send($sock, "get @{$sock_keys{$sock}}\r\n", MSG_NOSIGNAL)) {
            push @gather, $sock;
        } else {
            _dead_sock($sock);
        }
    }
    # pass 2: parse responses
    foreach my $sock (@gather) {
        _load_items($sock, \%val);
    }
    if ($self->{'debug'}) {
        while (my ($k, $v) = each %val) {
            print STDERR "MemCache: got $k = $v\n";
        }
    }
    return \%val;
}

sub _load_items {
    my ($sock, $ret) = @_;
    use bytes; # return bytes from length()
    while (1) {
	my $decl = readline($sock);
	if ($decl eq "END\r\n") {
	    return 1;
	} elsif ($decl =~ /^VALUE (\S+) (\d+) (\d+)\r\n$/) {
	    my ($rkey, $flags, $len) = ($1, $2, $3);
            my $bneed = $len+2;  # with \r\n
            my $offset = 0;

            while ($bneed > 0) {
                my $n = read($sock, $ret->{$rkey}, $bneed, $offset);
                last unless $n;
                $offset += $n;
                $bneed -= $n;
            }

            unless ($offset == $len+2) {
                # something messed up.  let's abort.
                delete $ret->{$rkey};
                _close_sock($sock);
                return 0;
            }

            # remove trailing \r\n
            chop $ret->{$rkey}; chop $ret->{$rkey};

	    $ret->{$rkey} = Compress::Zlib::memGunzip($ret->{$rkey})
		if $HAVE_ZLIB && $flags & F_COMPRESS;
	    $ret->{$rkey} = Storable::thaw($ret->{$rkey})
		if $flags & F_STORABLE;
	} else {
	    print STDERR "Error parsing memcached response\n";
	    return 0;
	}
    }
}

sub _hashfunc {
    my $hash = 0;
    foreach (split //, shift) {
        $hash = $hash*33 + ord($_);
    }
    return $hash;
}

1;
__END__

=head1 NAME

MemCachedClient - client library for memcached (memory cache daemon)

=head1 SYNOPSIS

  use MemCachedClient;

  $memc = new MemCachedClient {
    'servers' => [ "10.0.0.15:11211", "10.0.0.15:11212", 
                   "10.0.0.17:11211", [ "10.0.0.17:11211", 3 ] ],
    'debug' => 0,
    'compress_threshold' => 10_000,
  };
  $memc->set_servers($array_ref);
  $memc->set_compress_threshold(10_000);
  $memc->enable_compress(0);

  $memc->set("my_key", "Some value");
  $memc->set("object_key", { 'complex' => [ "object", 2, 4 ]});

  $val = $memc->get("my_key");
  $val = $memc->get("object_key");
  if ($val) { print $val->{'complex'}->[2]; }

  $memc->incr("key");
  $memc->decr("key");
  $memc->incr("key", 2);

=head1 DESCRIPTION

This is the Perl API for memcached, a distributed memory cache daemon.
More information is available at:

  http://www.danga.com/memcached/

=head1 CONSTRUCTOR

=over 4

=item C<new>

Takes one parameter, a hashref of options.  The most important key is
C<servers>, but that can also be set later with the C<set_servers>
method.  The servers must be an arrayref of hosts, each of which is
either a scalar of the form C<10.0.0.10:11211> or an arrayref of the
former and an integer weight value.  (The default weight if
unspecified is 1.)  It's recommended that weight values be kept as low
as possible, as this module currently allocates memory for bucket
distribution proportional to the total host weights.

Use C<compress_threshold> to set a compression threshold, in bytes.
Values larger than this threshold will be compressed by C<set> and
decompressed by C<get>.

The other useful key is C<debug>, which when set to true will produce
diagnostics on STDERR.

=back

=head1 METHODS

=over 4

=item C<set_servers>

Sets the server list this module distributes key gets and sets between.
The format is an arrayref of identical form as described in the C<new>
constructor.

=item C<set_debug>

Sets the C<debug> flag.  See C<new> constructor for more information.

=item C<set_compress_threshold>

Sets the compression threshold. See C<new> constructor for more information.

=item C<enable_compress>

Temporarily enable or disable compression.  Has no effect if C<compress_threshold>
isn't set, but has an overriding effect if it is.

=item C<get>

my $val = $mem->get($key);

Retrieves a key from the memcache.  Returns the value (automatically
thawed with Storable, if necessary) or undef.

The $key can optionally be an arrayref, with the first element being the
hash value, if you want to avoid making this module calculate a hash
value.  You may prefer, for example, to keep all of a given user's
objects on the same memcache server, so you could use the user's
unique id as the hash value.

=item C<get_multi>

my $hashref = $mem->get_multi(@keys);

Retrieves multiple keys from the memcache doing just one query.
Returns a hashref of key/value pairs that were available.

This method is recommended over regular 'get' as it lowers the number
of total packets flying around your network, reducing total latency,
since your app doesn't have to wait for each round-trip of 'get'
before sending the next one.

=item C<set>

$mem->set($key, $value);

Unconditionally sets a key to a given value in the memcache.  Returns true
if it was stored successfully.

The $key can optionally be an arrayref, with the first element being the
hash value, as described above.

=item C<add>

$mem->add($key, $value);

Like C<set>, but only stores in memcache if the key doesn't already exist.

=item C<replace>

$mem->replace($key, $value);

Like C<set>, but only stores in memcache if the key already exists.  The
opposite of C<add>.

=item C<incr>

$mem->incr($key[, $value]);

Sends a command to the server to atomically increment the value for
$key by $value, or by 1 if $value is undefined.  Returns undef if $key
doesn't exist on server, otherwise it returns the new value after
incrementing.  Value should be zero or greater.  Overflow on server
is not checked.  Be aware of values approaching 2**32.  See decr.

=item C<decr>

$mem->decr($key[, $value]);

Like incr, but decrements.  Unlike incr, underflow is checked and new
values are capped at 0.  If server value is 1, a decrement of 2
returns 0, not -1.

=back

=head1 BUGS

When a server goes down, this module does detect it, and re-hashes the
request to the remaining servers, but the way it does it isn't very
clean.  The result may be that it gives up during its rehashing and
refuses to get/set something it could've, had it been done right.

=head1 COPYRIGHT

This module is Copyright (c) 2003 Brad Fitzpatrick.
All rights reserved.

You may distribute under the terms of either the GNU General Public
License or the Artistic License, as specified in the Perl README file.

=head1 WARRANTY

This is free software. IT COMES WITHOUT WARRANTY OF ANY KIND.

=head1 FAQ

See the memcached website:
   http://www.danga.com/memcached/

=head1 AUTHOR

Brad Fitzpatrick <brad@danga.com>
