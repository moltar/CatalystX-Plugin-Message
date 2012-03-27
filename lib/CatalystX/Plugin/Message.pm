package CatalystX::Plugin::Message;

use Moose::Role;
use Storable qw(freeze thaw);
use MIME::Base64 qw(encode_base64 decode_base64);
use Try::Tiny;
use Carp qw(carp);
use namespace::autoclean;

use version; our $VERSION = version->declare("v0.1");

has 'message_session_key' => (
    is      => 'ro',
    isa     => 'Str',
    writer  => '_set_message_session_key',
    default => '__messages',
);

has 'message_token_param' => (
    is      => 'ro',
    isa     => 'Str',
    writer  => '_set_message_token_param',
    default => 'mid',
);

has 'message_token_length' => (
    is      => 'ro',
    isa     => 'Int',
    writer  => '_set_message_token_length',
    default => 5,
);

has 'message_serializer_param' => (
    is      => 'ro',
    isa     => 'Str',
    writer  => '_set_message_serializer_param',
    default => 'message',
);

has 'messages' => (
    is      => 'rw',
    isa     => 'ArrayRef[Value|ArrayRef|HashRef]',
    traits  => ['Array'],
    default => sub { [] },
    clearer => 'clear_messages',
    handles => {
        add_message    => 'push',
        add_messages   => 'push',
        all_messages   => 'elements',
        count_messages => 'count',
        has_messages   => 'count',
    },
);

### ENSURE IT WORKS WITH MULTIPLE REDIRECTS

sub BUILD {
    my $c = shift;
    
    if (my $config = $c->config->{'Plugin::Message'}) {
        foreach my $key (qw/session_key token_param token_length
            serializer_param/) {
            next unless exists $config->{$key};
            my $attr = "_set_message_$key";
            $c->$attr($config->{$key});
        }
    }
}

before 'finalize_headers' => sub {
    my $c = shift;

    ## we only care about redirects
    return unless $c->response->location;

    ## grab existing redirect URL
    my $redirect = URI->new($c->response->location);

    ## only set redirect messages on internal redirects
    return unless $c->_is_internal_redirect($c->request->uri, $redirect);
    
    ## make sure we have Session plugin first
    my %query_param = ();
    if ($c->can('session')) {
        ## warn user of convinience
        $c->log->debug('Need Plugin::Session to maintain message '
            . 'state on redirect.') if $c->debug;

        ## generate unique token
        my $token;
        do {
            $token = $c->generate_session_token($c->message_token_length);
        } while (exists $c->session->{$c->message_session_key}{$token});

        ## copy all messages to session
        $c->session->{$c->message_session_key}{$token} = [ $c->all_messages ];

        $query_param{$c->message_token_param} = $token;
    } else {
        $query_param{$c->message_serializer_param} =
            $c->message_freeze([ $c->all_messages ]);
    }

    ## add query params
    $redirect->query_param(%query_param);

    ## update location
    $c->response->location($redirect->as_string);
};

after 'prepare_action' => sub {
    my $c = shift;
    
    ## only process GET requests
    return unless $c->request->method eq 'GET';
    
    ## session message
    if (my $mid = delete $c->req->params->{$c->message_token_param}) {
        ## fetch and remove messasges
        my $messages = delete $c->session->{$c->message_session_key}{$mid};
        
        ## make sure we have an arrayref
        if ($messages && ref $messages eq 'ARRAY') {
            $c->add_messages($messages);
        }
    }

    ## frozen messages
    if (my $message = delete $c->req->params->{$c->message_serializer_param}) {
        ## fetch and thaw messasges
        my $messages = $c->message_thaw($message);

        ## make sure we have an arrayref
        if ($messages && ref $messages eq 'ARRAY') {
            $c->add_messages($messages);
        }
    }
};

sub _is_internal_redirect {
    my ($c, $req, $red) = @_;
    return $req->host eq $red->host;
}

sub generate_session_token {
    my ($c, $length) = @_;

    my @chars = ('a'..'z', 'A'..'Z', '0'..'9');
    my $random;
    foreach (1 .. $length) {
        $random .= $chars[rand @chars];
    }

    return $random;
}

sub message_freeze {
    my ($c, $message) = @_;

    my $frozen;
    try   { $frozen = encode_base64(freeze($message)); }
    catch { carp "Cannot freeze message: $_"; };

    return $frozen;
}

sub message_thaw {
    my ($c, $message) = @_;
    
    my $thawed;
    try   { $thawed = thaw(decode_base64($message)); }
    catch { carp "Cannot thaw message: $_"; };

    return $thawed;
}

1; # eof
