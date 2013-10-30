=head1 NAME

Tuba::Controller -- base class for controllers.

=cut

package Tuba::Controller;
use Mojo::Base qw/Mojolicious::Controller/;
use Tuba::DB::Objects qw/-nicknames/;
use Rose::DB::Object::Util qw/unset_state_in_db/;
use List::Util qw/shuffle/;
use Tuba::Search;
use Pg::hstore qw/hstore_encode/;
use Path::Class qw/file/;
use Tuba::Log;
use File::Temp;

=head2 list

Generic list.

=cut

sub list {
    my $c = shift;
    my $objects = $c->stash('objects');
    my $all = $c->param('all') ? 1 : 0;
    unless ($objects) {
        my $manager_class = $c->stash('manager_class') || $c->_guess_manager_class;
        $objects = $manager_class->get_objects(sort_by => "identifier", $all ? () : (page => $c->page, per_page => $c->per_page));
        $c->set_pages($manager_class->get_objects_count) unless $all;
    }
    my $object_class = $c->stash('object_class') || $c->_guess_object_class;
    my $meta = $object_class->meta;
    my $table = $meta->table;
    my $template = $c->param('thumbs') ? 'thumbs' : 'objects';
    $c->respond_to(
        json => sub {
            my $c = shift;
            if (my $page = $c->stash('page')) {
                $c->res->headers->accept_ranges('page');
                $c->res->headers->content_range(sprintf('page %d/%d',$page,$c->stash('pages')));
            }
            # Trees are smaller when getting all objects.
            $c->render(json => [ map $_->as_tree(c => $c, bonsai => $all), @$objects ]) },
        html => sub {
             my $c = shift;
             $c->render_maybe(template => "$table/$template", meta => $meta, objects => $objects )
                 or
             $c->render(template => $template, meta => $meta, objects => $objects )
         }
    );
};

=head2 show

Subclasses should override this but may call it for rendering,
after setting 'object' and 'meta'.

=cut

sub show {
    my $c = shift;

    my $object = $c->stash('object') or die "no object";
    my $meta  = $c->stash('meta') || $object->meta;
    $c->stash(meta => $meta) unless $c->stash('meta');
    my $table = $meta->table;
    $c->stash(relationships => $c->_order_relationships(meta => $meta));

    $c->respond_to(
        json  => sub { my $c = shift; $c->render_maybe(template => "$table/object") or $c->render(json => $object->as_tree(c => $c) ); },
        ttl   => sub { my $c = shift; $c->render_maybe(template => "$table/object") or $c->render(template => "object") },
        html  => sub { my $c = shift; $c->render_maybe(template => "$table/object") or $c->render(template => "object") },
        nt    => sub { shift->render_partial_ttl_as($table,'ntriples'); },
        rdfxml=> sub { shift->render_partial_ttl_as($table,'rdfxml'); },
        dot   => sub { shift->render_partial_ttl_as($table,'dot'); },
        rdfjson => sub { shift->render_partial_ttl_as($table,'json'); },
        jsontriples => sub { shift->render_partial_ttl_as($table,'json-triples'); },
        svg   => sub {
            my $c = shift;
            $c->res->headers->content_type('image/svg+xml');
            $c->render_partial_ttl_as($table,'svg'); },
    );
};

=head2 select

Called as a bridge, e.g. for /report/:report_identifier/figure/:figure_identifier

=cut

sub select {
    my $c = shift;
    my $loaded = $c->_this_object;
    if ($loaded) {
        my $table = $loaded->meta->table;
        $c->stash($table => $loaded);
        return 1;
    }
    $c->render_not_found;
    return 0;
}

sub _guess_object_class {
    my $c = shift;
    my $class = ref $c;
    my ($object_class) = $class =~ /::(.*)$/;
    $object_class = 'Tuba::DB::Object::'.$object_class;
    $object_class->can('meta') or die "can't figure out object class for $class (not $object_class)";
    return $object_class;
}

sub _guess_manager_class {
    my $c = shift;
    my $class = ref $c;
    my ($object_class) = $class =~ /::(.*)$/;
    $object_class = 'Tuba::DB::Object::'.$object_class;
    $object_class->can('meta') or die "can't figure out object class for $class (not $object_class)";
    return $object_class.'::Manager';
}


=head2 create_form

Create a default form.  If this is overriden by a subclass,
the template in <table>/create_form.html.ep will be used automatically,
instead of the default create_form.html.ep.

=cut

sub create_form {
  my $c = shift;
  my $controls = $c->stash('controls') || {};
  $c->stash(controls => {$c->_default_controls, %$controls});
  my $object_class = $c->_guess_object_class;
  my $table        = $object_class->meta->table;
  $c->stash(object_class => $object_class);
  $c->stash(meta         => $object_class->meta);
  $c->stash(cols => $c->_order_columns(meta => $object_class->meta));
  $c->render_maybe(template => "$table/create_form")
    or $c->render(template => "create_form");
}

sub _order_columns {
    my $c = shift;
    my %a = @_;
    my $meta = $a{meta};
    my @first = qw/report_identifier chapter_identifier identifier number ordinal title caption statement/;
    my @ordered;
    my %col_names = map { $_->name => $_ } $meta->columns;
    for my $name (@first, keys %col_names) {
        my $this = delete $col_names{$name} or next;
        push @ordered, $this;
    }
    return \@ordered;
}

sub _order_relationships {
    my $c = shift;
    my %a = @_;
    my $meta = $a{meta};
    my @first = qw/report reports chapter chapters/;
    my @ordered;
    my %rel_names = map { $_->name => $_ } $meta->relationships;
    for my $name (@first, keys %rel_names) {
        my $this = delete $rel_names{$name} or next;
        push @ordered, $this;
    }
    return \@ordered;
}


sub _redirect_to_view {
    my $c = shift;
    my $object = shift;
    my $url = $object->uri($c);
    return $c->redirect_to( $url );
}

=head2 create

Generic create.  See above for overriding.

=cut

sub create {
    my $c = shift;
    my $class = ref $c;
    my ($object_class) = $class =~ /::(.*)$/;
    $object_class = 'Tuba::DB::Object::'.$object_class;
    my $computed = $c->stash('computed_params') || {}; # to override incoming params in a subclass.
    my %obj;
    if (my $json = $c->req->json) {
        %obj = %$json;
    } else {
        for my $col ($object_class->meta->columns) {
            my $got = $computed->{$col->name} // $c->param($col->name);
            $got = $c->normalize_form_parameter(column => $col->name, value => $got);
            $obj{$col->name} = defined($got) && length($got) ? $got : undef;
        }
    }
    if (exists($obj{report_identifier}) && $c->stash('report_identifier')) {
        $obj{report_identifier} = $c->stash('report_identifier');
    }
    my $new = $object_class->new(%obj);
    $new->meta->error_mode('return');
    my $table = $object_class->meta->table;
    $new->save(audit_user => $c->user) and return $c->_redirect_to_view($new);
    $c->respond_to(
        json => sub {
                my $c = shift;
                $c->res->code(409);
                $c->render(json => { error => $new->error } );
            },
        html => sub {
                my $c = shift;
                $c->flash(error => $new->error);
                $c->redirect_to($object_class->uri($c,{tab => "create_form"}));
            }
        );
}

sub _this_object {
    my $c = shift;
    my $object_class = $c->_guess_object_class;
    my $meta = $object_class->meta;
    my %pk;
    for my $name ($meta->primary_key_column_names) { ; # e.g. identifier, report_identifier
        my $stash_name = $name;
        $stash_name = $meta->table.'_'.$name if $name eq 'identifier';
        $stash_name .= '_identifier' unless $stash_name =~ /identifier/;
        my $val = $c->stash($stash_name) or do {
            $c->app->log->warn("No values for $name when loading $object_class");
            return;
        };
        $pk{$name} = $val;
    }

    my $object = $object_class->new(%pk)->load(speculative => 1);
    return $object;
}

sub _chaplist {
    my $c = shift;
    my $report_identifier = shift;
    my @chapters = @{ Chapters->get_objects(query => [ report_identifier => $report_identifier ], sort_by => 'number') };
    return [ '', map [ sprintf( '%s %s', ( $_->number || '' ), $_->title ), $_->identifier ], @chapters ];
}
sub _rptlist {
    my $c = shift;
    my @reports = @{ Reports->get_objects(sort_by => 'identifier') };
    return [ '', map [ sprintf( '%s : %.80s', ( $_->identifier || '' ), ($_->title || '') ), $_->identifier ], @reports ];
}
sub _default_controls {
    my $c = shift;
    return (
        organization_identifier => sub {
            my $c = shift;
            { template => 'autocomplete', params => { object_type => 'organization' } }
        },
        chapter_identifier => sub { my $c = shift;
                            +{ template => 'select',
                               params => { values => $c->_chaplist($c->stash('report_identifier')) } } },
        report_identifier  => sub { +{ template => 'select',
                                params => { values => shift->_rptlist() } } },
    );
}

sub _default_rel_controls {
    my $c = shift;
    return (
    chapter => sub { my ($c,$obj) = @_;
                         +{ template => 'select',
                            params => { values => $c->_chaplist($c->stash('report_identifier')),
                                        column => $obj->meta->column('chapter_identifier'),
                                        value => $obj->chapter_identifier }
                        } },
    report => sub { my ($c,$obj) = @_;
                      +{ template => 'select',
                         params => { values => $c->_rptlist(),
                                     column => $obj->meta->column('report_identifier'),
                                     value => $obj->report_identifier } } },
    );
}


=head2 update_form

Generic update_form.

=cut

sub update_form {
    my $c = shift;
    my $controls = $c->stash('controls') || {};
    $c->stash(controls => { $c->_default_controls, %$controls } );
    my $object = $c->_this_object or return $c->render_not_found;
    $c->stash(object => $object);
    $c->stash(meta => $object->meta);
    $c->stash(cols => $c->_order_columns(meta => $object->meta));
    my $format = $c->detect_format;
    if ($format eq 'json') {
        return $c->render(json => $object->as_tree(max_depth => 0));
    }
    $c->render(template => "update_form");
}

=head2 update_prov_form

Generic update_prov_form.

=cut

sub update_prov_form {
    my $c = shift;
    my $object = $c->_this_object or return $c->render_not_found;
    $c->stash(object => $object);
    $c->stash(meta => $object->meta);
    my $pub = $object->get_publication(autocreate => 1) or return $c->render(text => $object->meta->table.' is not a publication');
    $c->stash(publication => $pub);
    my $parents = [];
    if ($pub) {
        $parents = [ $pub->get_parents ];
    }
    $c->stash( parents => $parents );
    $c->render(template => "update_prov_form");
}

sub _text_to_object {
    my $c = shift;
    my $str = shift or return;
    return $c->Tuba::Search::autocomplete_str_to_object($str);
}

=head2 update_prov

Update the provenance for this object.

=cut

sub update_prov {
    my $c = shift;
    my $object = $c->_this_object or return $c->render_not_found;
    $c->stash(object => $object);
    $c->stash(meta => $object->meta);
    my $pub = $object->get_publication(autocreate => 1);
    $pub->save(changes_only => 1, audit_user => $c->user); # might be new.
    $c->stash(publication => $pub);
    $c->stash->{template} = 'update_prov_form';

    if (my $delete = $c->param('delete_publication')) {
        my $rel = $c->param('delete_relationship');
        my $other_pub = Publication->new(id => $delete)->load(speculative => 1);
        my $map = PublicationMap->new(child => $pub->id, parent => $delete, relationship => $rel);
        $map->load(speculative => 1) or return $c->render(error => "could not find relationship");
        $map->delete(audit_user => $c->user) or return $c->render(error => $map->error);
        $c->stash(info => "Deleted $rel ".($other_pub ? $other_pub->stringify : ""));
        return $c->render;
    }

    my $parent_str = $c->param('parent') or return $c->render;
    my $rel = $c->param('parent_rel')    or return $c->render(error => "Please select a relationship");
    my $parent = $c->_text_to_object($parent_str) or return $c->render(error => 'cannot parse publication');
    my $parent_pub = $parent->get_publication(autocreate => 1);
    $parent_pub->save(changes_only => 1, audit_user => $c->user) or return $c->render(error => $pub->error);

    my $map = PublicationMap->new(
        child        => $pub->id,
        parent       => $parent_pub->id,
        relationship => $rel,
        note         => ( ($c->param('note') || undef) ),
    );

    $map->save(audit_user => $c->user) or return $c->render(error => $map->error);

    $c->stash(info => "Saved $rel : ".$parent_pub->stringify);
    return $c->render;
}

=head2 update_rel_form

Form for updating the relationships.

Override this and set 'relationships' to relationships that should
be on this page, e.g.

    $c->stash(relationships => [ map Figure->meta->relationship($_), qw/images/ ]);

=cut

sub update_rel_form {
    my $c = shift;
    my $object = $c->_this_object or return $c->render_not_found;
    my $controls = $c->stash('controls') || {};
    $c->stash(controls => { $c->_default_rel_controls, %$controls } );
    my $meta = $object->meta;
    $c->stash(object => $object);
    $c->stash(meta => $meta);
    $c->render(template => "update_rel_form");
}

=head2 update_files_form

Form for updating files.

=cut

sub update_files_form {
    my $c = shift;
    my $object = $c->_this_object or return $c->render_not_found;
    $c->stash(object => $object);
    $c->stash(meta => $object->meta);
    $c->render(template => "update_files_form");
}

=head2 update_files

Update the files.

=cut

sub update_files {
    my $c = shift;
    my $object = $c->_this_object or return $c->render_not_found;
    my $next = $object->uri($c,{tab => 'update_files_form'});

    my $pub = $object->get_publication(autocreate => 1) or do {
        $c->flash(error => "Sorry, files uploads have only been implemented for publications.");
        # TODO
        return $c->redirect_to($next);
    };

    my $file = $c->req->upload('file_upload');
    if ($file && $file->size) {
        $pub->upload_file(c => $c, upload => $file) or do {
            $c->flash(error => $pub->error);
            return $c->redirect_to($next);
        }
    }
    if (my $file_url = $c->param('file_url')) {
        $c->app->log->info("Getting $file_url for ".$object->meta->table."  ".(join '/',$object->pk_values));
        my $tx = $c->app->ua->get($file_url);
        my $res = $tx->success or do {
            $c->flash(error => "Error getting $file_url : ".$tx->error);
            return $c->redirect_to($next);
        };
        my $content = $res->body;

        my $filename = Mojo::URL->new($file_url)->path->parts->[-1];
        my $up = Mojo::Upload->new;
        $up->filename($filename);
        $up->asset(Mojo::Asset::File->new->add_chunk($content));
        $pub->upload_file(c => $c, upload => $up) or do {
            $c->flash(error => $pub->error);
            return $c->redirect_to($next);
        }
    }

    my $image_dir = $c->config('image_upload_dir') or do { logger->error("no image_upload_dir configured"); die "configuration error"; };
    if (my $id = $c->param('delete_file')) {
        my $obj = File->new(identifier => $id)->load(speculative => 1) or do {
            $c->flash(error => "could not find file $id");
            return $c->redirect_to($next);
        };
        $obj->meta->error_mode('return');
        my $filename = "$image_dir".'/'.$obj->file;
        my $entry = PublicationFileMap->new(
            publication => $pub->id,
            file => $obj->identifier
        );
        $entry->delete or do {
            $c->flash(error => $obj->error);
            return $c->redirect_to($next);
        };
        $obj = File->new(identifier => $obj->identifier)->load;
        my @others = $obj->publications;
        unless (@others) {
            $obj->delete or do {
                $c->flash(error => $obj->error);
                return $c->redirect_to($next);
            };
            -e $filename and do { unlink $filename or die $!; };
        }
        $c->flash(message => 'Saved changes');
        return $c->redirect_to($next);
    }


    return $c->redirect_to($next);
}

=head2 put_files

PUT files.

=cut

sub put_files {
    my $c = shift;
    my $file = Mojo::Upload->new(asset => Mojo::Asset::File->new->add_chunk($c->req->body));
    $file->filename($c->stash("filename") ||  'asset');
    my $obj = $c->_this_object;
    my $pub = $obj->get_publication(autocreate => 1);
    $pub->upload_file(c => $c, upload => $file) or do {
        return $c->render(status => 500, text => $pub->error);
    };
    $c->render(text => "ok");
}

=head2 update_rel

Update the relationships.

=cut

sub update_rel {
    my $c = shift;
    # TODO
    $c->render(text => 'saving not implemented');
}


=head2 update

Generic update for an object.

=cut

sub _differ {
    my ($x,$y) = @_;
    return 1 if !defined($x) && defined($y);
    return 1 if defined($x) && !defined($y);
    return 0 if !defined($x) && !defined($y);
    return 1 if $x ne $y;
    return 0;
}

sub normalize_form_parameter {
    my $c = shift;
    my %args = @_;
    my ($column, $value) = @args{qw/column value/};
    if ($column eq 'organization_identifier') {
        my $org = Organization->new_from_autocomplete($value);
        return $org->identifier if $org;
    }
    return $value;
}

sub update {
    my $c = shift;
    my $object = $c->_this_object or return $c->render_not_found;
    my $next = $object->uri($c,{tab => 'update_form'});
    my %pk_changes;
    my %new_attrs;
    my $table = $object->meta->table;
    my $computed = $c->stash('computed_params') || {}; # to override incoming params in a subclass.
    $object->meta->error_mode('return');
    my $json = $c->req->json;

    if ($c->param('delete')) {
        if ($object->delete) {
            $c->flash(message => "Deleted $table");
            return $c->redirect_to('list_'.$table);
        }
        $c->flash(error => $object->error);
        return $c->redirect_to($next);
    }

    for my $col ($object->meta->columns) {
        my $param = $json ? $json->{$col->name} : $c->req->param($col->name);
        $param = $computed->{$col->name} if exists($computed->{$col->name});
        $param = $c->stash('report_identifier') if $col->name eq 'report_identifier' && $c->stash('report_identifier');
        $param = $c->normalize_form_parameter(column => $col->name, value => $param);
        $param = undef unless defined($param) && length($param);
        my $acc = $col->accessor_method_name;
        $new_attrs{$col->name} = $object->$acc; # Set to old, then override with new.
        $new_attrs{$col->name} = $param if _differ($param,$new_attrs{$col->name});
        if ($col->is_primary_key_member && $param ne $object->$acc) {
            $pk_changes{$col->name} = $param;
            # $c->app->log->debug("Setting primary key member ".$col->name." to $param");
            next;
        }
        $c->app->log->debug("Setting $acc to ".($param // 'undef'));
        $object->$acc($param);
    }

    my $ok = 1;
    if (keys %pk_changes) {
        $c->app->log->debug("Updating primary key");
        # See Tuba::DB::Object.
        if (my $new = $object->update_primary_key(audit_user => $c->user, %pk_changes, %new_attrs)) {
            $new->$_($object->$_) for map { $_->is_primary_key_member ? () : $_->name } $object->meta->columns;
            $object = $new;
        } else {
            $ok = 0;
        }
    }


    $ok = $object->save(changes_only => 1, audit_user => $c->user) if $ok;
    if ($c->detect_format eq 'json') {
        return $c->update_form if $ok;
        return $c->render(json => { error => $object->error });
    }
    $ok and do {
        $next = $object->uri($c,{tab => 'update_form'});
        $c->flash(message => "Saved changes"); return $c->redirect_to($next); };
    $c->flash(error => $object->error);
    $c->redirect_to($next);
}

=head2 remove

Generic delete

=cut

sub remove {
    my $c = shift;
    my $object = $c->_this_object or return $c->render_not_found;
    $object->meta->error_mode('return');
    $object->delete or return $c->render_exception($object->error);
    return $c->render(text => 'ok');
}

=head2 index

Handles / for tuba.

=cut

sub index {
    my $c = shift;
    state $count;
    unless ($count) {
        $count = Publications->get_objects_count;
    }
    my $demo_pubs;
    push @$demo_pubs, @{ Publications->get_objects(
            offset => ( int rand $count ),
            limit => 1,
        ) } for (1..6);
    $c->stash(demo_pubs => [ shuffle @$demo_pubs ]);
    $c->render(template => 'index');
}

=item history

Generic history of changes to an object.

[ 'audit_username', 'audit_note', 'table_name', 'changed_fields', 'action_tstamp_tx', 'action' ],

=cut

sub history {
    my $c = shift;
    my $object = $c->_this_object or return $c->render_not_found;
    my $pk = $object->meta->primary_key;
    my @columns = $pk->column_names;

    my %bind  = map {( "pkval_$_" => $object->$_ )} @columns;
    my $where = join ' and ', map qq{ row_data->'$_' = :pkval_$_ }, @columns;
    # TODO: also look for pk changes in changed_fields->'$pk' = :pkval_$pk) };
    my $result = $c->dbc->select(
        [ '*', 'extract(epoch from action_tstamp_tx) as sort_key' ],
        table => "audit.logged_actions",
        where => [ $where, \%bind ],
        append => 'order by action_tstamp_tx desc',
    );
    my $change_log = $result->all;

    # Also look for provenance changes.
    if (my $pub = $object->get_publication) {
        my $id = $pub->id;
        my $more = $c->dbc->select(
            [ '*', 'extract(epoch from action_tstamp_tx) as sort_key' ],
            table  => "audit.logged_actions",
            where  => [ "row_data->'child' = :id", { id => $id } ],
            append => 'order by action_tstamp_tx desc',
        );

        $change_log = [ @{ $more->all }, @$change_log ];
        @$change_log = sort { $b->{sort_key} cmp $a->{sort_key} } @$change_log;
    }

    $c->render(template => 'history', change_log => $change_log, object => $object, pk => $pk)
}

sub render {
    my $c = shift;
    my %args = @_;
    my $obj = $c->stash('object') || $args{object} or return $c->SUPER::render(@_);
    my $moniker = $obj->moniker;
    if (!defined($c->stash($moniker))) {
        $c->stash($moniker => $obj);
    }
    return $c->SUPER::render(@_);
}

sub page {
    my $c = shift;
    my $page = $c->param('page') || 1;
    $page = $c->_favorite_page if $page eq '♥';
    if (my $accept = $c->req->headers->content_range) {
        if ($accept =~ /^page=(\d+)$/i) {
            $page = $1;
        }
    }
    $page = 1 unless $page && $page =~ /^\d+$/;
    $c->stash(page => $page);
    return $page;
}

sub per_page {
    my $c = shift;
    return 21 if $c->param('thumbs');
    return 20;
}

sub set_pages {
    my $c = shift;
    my $count = shift || 1;
    $c->stash(pages => 1 + int(($count - 1)/$c->per_page));
}

1;
