package DJabberd::Delivery::Local;
use strict;
use warnings;
use base 'DJabberd::Delivery';
use Scalar::Util qw(blessed);

sub run_before { ("DJabberd::Delivery::S2S") }

sub deliver {
    my ($self, $vhost, $cb, $stanza) = @_;
    my $to = $stanza->to_jid                or return $cb->declined;

    # we only do local delivery. if its not to a domain we host, pass it through
    return $cb->declined unless $vhost->handles_domain($to->domain);

    # helper, all current available sessions for target user
    my $all_available_conns = sub {
        grep { $_->is_available || $stanza->deliver_when_unavailable } $vhost->find_conns_of_bare($to)
    };

    # helper, deliver to all available conns
    my $deliver_to = sub {
        my @conns = @_;

        $DJabberd::Stats::counter{deliver_local}++;

        $stanza->replace_ns("jabber:server", "jabber:client");

        foreach my $c (@conns) {
            $c->send_stanza($stanza);
        }

        return $cb->delivered;
    };

    my $unhandled = sub {
        my $n = $all_available_conns->();

        # shouldn't get here. warn and drop stanza
        warn "UNHANDLED STANZA TO LOCAL $to, $n avail conns: ".$stanza->as_xml."\n";
        return $cb->delivered;
    };

    # to JID only, no session (resource)
    if ($to->is_bare) {
        # send to all available sessions
        # XXX check behaviour against RFC
        return $deliver_to->($all_available_conns->());
    }

    # to specific session (resource)

    # XXX stanza classes themselves should maybe hold this logic
    my $class = blessed $stanza;
    my $type = $stanza->{attrs}{"{}type"};

    # find session. if its available or we're allowed to deliver anyway, then deliver
    # RFC 6121 §8.5.3.1
    # XXX not checked against RFC
    my $dest = $vhost->find_jid($to);
    if ($dest && ($dest->is_available || $stanza->deliver_when_unavailable)) {
        return $deliver_to->($dest);
    }

    # session not found, but other sessions exist
    # RFC 6121 §8.5.3.2
    if (my @avail_conns = $all_available_conns->()) {

        # 8.5.3.2.1. Message
        if ($class eq "DJabberd::Message") {

            # chat may be delivered to all available (point 4)
            if ($type eq "chat") {
                return $deliver_to->(@avail_conns);
            }

            # error MUST be silently ignored
            if ($type eq "error") {
                return $cb->delivered;
            }

            # normal, groupchat or headline SHOULD return service-unavailable
            # treating missing/unknown type as normal per §5.2.2
            $stanza->make_error_response('503', 'cancel', 'service-unavailable')->deliver($vhost);
            return $cb->delivered;
        }

        # 8.5.3.2.2. Presence
        if ($class eq "DJabberd::Presence") {

            # no type, unavailable, subscribed, unsubscribe, unsubscribed
            # MUST be silently ignored
            if (!defined $type || $type =~ m/^(?:unavailable|subscribed|unsubscribed?)$/) {
                return $cb->delivered;
            }

            # probe and subscribe handled elsewhere (I hope!)
            if ($type =~ m/^(?:subscribe|probe)$/) {
                return $cb->decline;
            }

            # anything else SHOULD return bad-request (per §4.7.1)
            $stanza->make_error_response('400', 'modify', 'bad-request')->deliver($vhost);
            return $cb->delivered;
        }

        # 8.5.3.2.3. IQ
        if ($class eq "DJabberd::IQ") {

            # server MUST return service-unavailable
            $stanza->make_error_response('503', 'cancel', 'service-unavailable')->deliver($vhost);
            return $cb->delivered;
        }

        return $unhandled->();
    }

    # session not available
    # RFC 6121 §8.5.1 and §8.5.2.2
    # we treat "user doesn't exist" the same as "user exists but has no available sessions"
    # in most cases that's ok because the valid behaviour for a nonexistent user is to silently ignore the stanza
    # sometimes we'll rely on the next hook to deal with that (eg offline storage, quietly fail if the user doesn't exist)

    # 8.5.2.2.1. Message
    if ($class eq "DJabberd::Message") {

        # groupchat MUST return service-unavailable
        if ($type eq "groupchat") {
            $stanza->make_error_response('503', 'cancel', 'service-unavailable')->deliver($vhost);
            return $cb->delivered;
        }

        # headline or error MUST be silently ignored
        if ($type =~ m/^(?:headline|error)$/) {
            return $cb->delivered;
        }

        # normal or chat SHOULD go to offline storage
        # treating missing/unknown type as normal per §5.2.2
        return $cb->declined;
    }

    # 8.5.2.2.2. Presence
    if ($class eq "DJabberd::Presence") {

        # no type or unavailable SHOULD be silently ignored
        if (!defined $type || $type eq "unavailable") {
            return $cb->delivered;
        }

        # subscriptions handled elsewhere
        if ($type =~ m/^(?:un)?subscribe(?:d)$/ || $type eq "probe") {
            return $cb->declined;
        }

        # anything else SHOULD return bad-request (per §4.7.1)
        $stanza->make_error_response('400', 'modify', 'bad-request')->deliver($vhost);
        return $cb->delivered;
    }

    # 8.5.2.2.3. IQ
    if ($class eq "DJabberd::IQ") {
        # all handled elsewhere
        return $cb->declined;
    }

    return $unhandled->();
}

1;
