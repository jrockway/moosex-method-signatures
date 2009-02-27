package MooseX::Method::Signatures::Meta::Method;

use Moose;
use Parse::Method::Signatures;
use Moose::Util qw/does_role/;
use Moose::Util::TypeConstraints;
use MooseX::Types::Structured qw/Tuple Dict Optional/;
use MooseX::Types::Moose qw/ArrayRef Str Maybe Object Defined CodeRef/;
use aliased 'Parse::Method::Signatures::Param::Named';

use namespace::clean -except => 'meta';

extends 'Moose::Meta::Method';

has signature => (
    is       => 'ro',
    isa      => Maybe[Str],
    required => 1,
);

has _parsed_signature => (
    is      => 'ro',
    isa     => class_type('Parse::Method::Signatures::Sig'),
    lazy    => 1,
    builder => '_build__parsed_signature',
);

has _lexicals => (
    is      => 'ro',
    isa     => ArrayRef[Str],
    lazy    => 1,
    builder => '_build__lexicals',
);

has _positional_args => (
    is      => 'ro',
    isa     => ArrayRef,
    lazy    => 1,
    builder => '_build__positional_args',
);

has _named_args => (
    is      => 'ro',
    isa     => ArrayRef,
    lazy    => 1,
    builder => '_build__named_args',
);

has type_constraint => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_type_constraint',
);

has actual_body => (
    is        => 'ro',
    isa       => CodeRef,
    writer    => '_set_actual_body',
    predicate => '_has_actual_body',
);

before actual_body => sub {
    my ($self) = @_;
    confess "method doesn't have an actual body yet"
        unless $self->_has_actual_body;
};

around wrap => sub {
    my ($orig, $class, %args) = @_;

    $args{actual_body} = delete $args{body}
        if exists $args{body};

    my $self;
    $self = $orig->($class, %args, body => sub {
        @_ = $self->validate(\@_);
        goto &{ $self->actual_body };
    });
    return $self;
};

sub _build__parsed_signature {
    my ($self) = @_;
    return Parse::Method::Signatures->signature(
        input => $self->signature,
        type_constraint_callback => sub {
            my ($tc, $name) = @_;
            my $code = $self->package_name->can($name);
            return $code
                ? eval { $code->() }
                : $tc->find_registered_constraint($name);
        },
    );
}

sub _param_to_spec {
    my ($self, $param) = @_;

    my $tc = Defined;
    $tc = $param->meta_type_constraint
        if $param->has_type_constraints;

    if ($param->has_constraints) {
        my $cb = join ' && ', map { "sub {${_}}->(\\\@_)" } $param->constraints;
        my $code = eval "sub {${cb}}";
        $tc = subtype($tc, $code);
    }

    my %spec;
    $spec{tc} = $param->required
        ? $tc
        : does_role($param, Named)
            ? Optional[$tc]
            : Maybe[$tc];

    $spec{default} = $param->default_value
        if $param->has_default_value;

    if ($param->has_traits) {
        for my $trait (@{ $param->param_traits }) {
            next unless $trait->[1] eq 'coerce';
            $spec{coerce} = 1;
        }
    }

    return \%spec;
}

sub _build__lexicals {
    my ($self) = @_;
    my ($sig) = $self->_parsed_signature;

    my @lexicals;
    push @lexicals, $sig->has_invocant
        ? $sig->invocant->variable_name
        : '$self';

    if ($sig->has_positional_params) {
        push @lexicals, $_->variable_name for $sig->positional_params;
    }

    if ($sig->has_named_params) {
        push @lexicals, $_->variable_name for $sig->named_params;
    }

    return \@lexicals;
}

sub _build__positional_args {
    my ($self) = @_;
    my $sig = $self->_parsed_signature;

    my @positional;

    push @positional, $sig->has_invocant
        ? $self->_param_to_spec($sig->invocant)
        : { tc => Object };

    if ($sig->has_positional_params) {
        for my $param ($sig->positional_params) {
            push @positional, $self->_param_to_spec($param);
        }
    }

    return \@positional;
}

sub _build__named_args {
    my ($self) = @_;
    my $sig = $self->_parsed_signature;

    my @named;

    if ($sig->has_named_params) {
        for my $param ($sig->named_params) {
            push @named, $param->label => $self->_param_to_spec($param);
        }
    }

    return \@named;
}

sub _build_type_constraint {
    my ($self) = @_;
    my ($positional, $named) = map { $self->$_ } map { "_${_}_args" } qw/positional named/;

    my $tc = Tuple[
        Tuple[ map { $_->{tc}               } @{ $positional } ],
        Dict[  map { ref $_ ? $_->{tc} : $_ } @{ $named      } ],
    ];

    my $coerce_param = sub {
        my ($spec, $value) = @_;
        return $value unless exists $spec->{coerce};
        return $spec->{tc}->coerce($value);
    };

    my %named = @{ $named };

    coerce $tc,
        from ArrayRef,
        via {
            my (@positional_args, %named_args);

            my $i = 0;
            for my $param (@{ $positional }) {
                push @positional_args,
                    $#{ $_ } < $i
                        ? (exists $param->{default} ? $param->{default} : ())
                        : $coerce_param->($param, $_->[$i]);
                $i++;
            }

            unless ($#{ $_ } < $i) {
                my %rest = @{ $_ }[$i .. $#{ $_ }];
                while (my ($key, $spec) = each %named) {
                    if (exists $rest{$key}) {
                        $named_args{$key} = $coerce_param->($spec, delete $rest{$key});
                        next;
                    }

                    if (exists $spec->{default}) {
                        $named_args{$key} = $spec->{default};
                    }
                }

                @named_args{keys %rest} = values %rest;
            }

            return [\@positional_args, \%named_args];
        };

    return $tc;
}

sub validate {
    my ($self, $args) = @_;

    my @named = grep { !ref $_ } @{ $self->_named_args };

    my $coerced = $self->type_constraint->coerce($args);
    confess 'failed to coerce'
        if $coerced == $args;

    if (defined (my $msg = $self->type_constraint->validate($coerced))) {
        confess $msg;
    }

    return @{ $coerced->[0] }, map { $coerced->[1]->{$_} } @named;
}

__PACKAGE__->meta->make_immutable;

1;
