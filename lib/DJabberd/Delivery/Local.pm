package DJabberd::Delivery::Local;
use strict;
use warnings;
use base 'DJabberd::Delivery';
use Scalar::Util qw(blessed);

sub run_before { ("DJabberd::Delivery::S2S") }

sub deliver {
    my ($self, $vhost, $cb, $stanza) = @_;
    my $to = $stanza->to_jid                or return $cb->declined;

    my @dconns;
    my $find_bares = sub {
        @dconns = grep { $_->is_available || $stanza->deliver_when_unavailable } $vhost->find_conns_of_bare($to)
    };

    if ($to->is_bare) {
        $find_bares->();
    } else {
        my $dest;
        if (($dest = $vhost->find_jid($to)) && ($dest->is_available || $stanza->deliver_when_unavailable)) {
            push @dconns, $dest;
        } else {

            # specific resource request, but not available. what we do depends on stanza type
            # XXX stanza classes themselves should hold this logic
            if (blessed $stanza eq "DJabberd::Message") {
                my $type = $stanza->{attrs}{"{}type"};
                if ($type =~ m/^(?:normal|groupchat|headline)$/) {
                    $stanza->make_error_response('503', 'cancel', 'service-unavailable')->deliver($vhost);
                    return $cb->delivered;
                }
            }

            $find_bares->();
        }
    }

    return $cb->declined unless @dconns;

    $DJabberd::Stats::counter{deliver_local}++;

    $stanza->replace_ns("jabber:server", "jabber:client");

    foreach my $c (@dconns) {
        $c->send_stanza($stanza);
    }

    $cb->delivered;
}

1;
