package DBIx::NoSQL::EntityModel;

use Modern::Perl;

use Any::Moose;

has store => qw/ is ro required 1 weak_ref 1 /;
has name => qw/ reader name writer _name required 1 /;

has inflate => qw/ accessor _inflate isa Maybe[CodeRef] /;
has deflate => qw/ accessor _deflate isa Maybe[CodeRef] /;
sub inflator { return shift->_inflate( @_ ) }
sub deflator { return shift->_deflate( @_ ) }

has field_map => qw/ is ro lazy_build 1 isa HashRef /;
sub _build_field_map { {} }
sub field {
    require DBIx::NoSQL::EntityModel::Field;
    my $self = shift;
    my $name = shift;

    return $self->field_map->{ $name } unless @_;

    die "Already have field ($name)" if $self->field_map->{ $name };
    my $field = $self->field_map->{ $name } = DBIx::NoSQL::EntityModel::Field->new( name => $name );
    $field->setup( $self, @_ );
    return $field;
}
has _field2column_map => qw/ is ro /, default => sub { {} };
has _field2inflate_map => qw/ is ro /, default => sub { {} };
has _field2deflate_map => qw/ is ro /, default => sub { {} };

sub set {
    my $self = shift;
    my $key = shift;
    my $data = shift;

    $data = $self->deflate( $data );
    my $value = $self->serialize( $data );

    $self->store->schema->resultset( '__Store__' )->update_or_create(
        { __model__ => $self->name, __key__ => $key, __value__ => $value },
        { key => 'primary' },
    );

    {
        my %set;
        $set{ $self->key_column } = $key;
        while( my ( $field, $column ) = each %{ $self->_field2column_map } ) {
            $set{ $column } = $data->{ $field };
        }

        $self->store->schema->resultset( $self->name )->update_or_create(
            \%set, { key => 'primary' },
        );
    }
}

sub get {
    my $self = shift;
    my $key = shift;

    my $result = $self->store->schema->resultset( '__Store__' )->find(
        { __model__ => $self->name, __key__ => $key },
        { key => 'primary' },
    );

    my $value = $result->get_column( '__value__' );
    my $data = $self->deserialize( $value );
    return $self->inflate( $data );
}

sub inflate {
    my $self = shift;
    my $data = shift;

    while( my ( $field, $inflator ) = each %{ $self->_field2inflate_map } ) {
        $data->{ $field } = $inflator->( $data->{ $field } ) if defined $data->{ $field };
    }
    #if ( my $inflate = $self->_inflate ) {
        #$data = $inflate->( $data, $self );
    #}

    return $data;
}

sub deflate {
    my $self = shift;
    my $data = shift;

    while( my ( $field, $deflator ) = each %{ $self->_field2deflate_map } ) {
        $data->{ $field } = $deflator->( $data->{ $field } ) if defined $data->{ $field };
    }
    #if ( my $deflate = $self->_deflate ) {
        #$data = $deflate->( $data, $self );
    #}

    return $data;
}

sub deserialize {
    my $self = shift;
    my $value  = shift;

    my $data = $self->store->json->decode( $value );
    return $data;
}

sub serialize {
    my $self = shift;
    my $data = shift;

    my $value = $self->store->json->encode( $data );
    return $value;
}

sub search {
    my $self = shift;

    require DBIx::NoSQL::Search;
    my $search = DBIx::NoSQL::Search->new( entity_model => $self );

    if ( @_ ) {
        $search->_where( $_[0] );
    }

    return $search;
}

has key_column => qw/ is rw isa Str lazy_build 1 /;
sub _build_key_column { 'key' }

has [qw/ create_statement drop_statement /] => qw/ is rw isa Maybe[Str] /;

sub prepare {
    my $self = shift;
    $self->register_result_class;
    $self->deploy;
}

has result_class_scaffold => qw/ is ro lazy_build 1 /;
sub _build_result_class_scaffold { return DBIx::NoSQL::ClassScaffold->new->become_ResultClass }
has result_class => qw/ is ro lazy_build 1 /;
sub _build_result_class { return shift->result_class_scaffold->package }

sub register_result_class {
    my $self = shift;

    my $store = $self->store;
    my $schema = $store->schema;
    my $name = $self->name;
    my $result_class = $self->result_class;

    $schema->unregister_source( $name ) if $schema->source_registrations->{ $name };

    {
        unless ( $result_class->can( 'result_source_instance' ) ) {
            $result_class->table( $name );
        }

        my $key_column = $self->key_column;
        unless( $result_class->has_column( $key_column ) ) {
            $result_class->add_column( $key_column => {
                data_type => 'text'
            } );
        }
        unless( $result_class->primary_columns ) {
            $result_class->set_primary_key( $key_column );
        }

        for my $field ( values %{ $self->field_map } ) {
            next unless $field->index;
            unless( $result_class->has_column( $field->name ) ) {
                $field->install_index( $self, $result_class );
            }
        }
    }

    $schema->register_class( $name => $result_class );

    my $table = $result_class->table;
    my $sql = $schema->build_sql;
    my @sql = split m/;\n/, $sql;
    my ( $create ) = grep { m/(?:(?i)CREATE\s+TABLE\s+)$table/ } @sql;
    my ( $drop ) = grep { m/(?:(?i)DROP\s+TABLE\s+.*)$table/ } @sql;

    $self->create_statement( $create );
    $self->drop_statement( $drop );
}

sub deploy {
    my $self = shift;

    my $store = $self->store;
    my $name = $self->name;

    my ( $count ) = $store->dbh->selectrow_array(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", undef, $name );
    if ( ! $count ) {
        $store->dbh->do( $self->create_statement );
    }
}

1;