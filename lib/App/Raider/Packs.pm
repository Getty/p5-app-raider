package App::Raider::Packs;
our $VERSION = '0.004';
# ABSTRACT: Pack discovery, loading, and management for raider personas and power bundles

use strict;
use warnings;
use Path::Tiny;
use YAML::PP ();
use JSON::MaybeXS ();
use File::ShareDir ();

# Pack class is defined below in this file

use Exporter 'import';
our @EXPORT_OK = qw( build_packs );

=func build_packs

    my $packs = App::Raider::Packs::build_packs(
        root     => '/path/to/project',  # chroot root
        packs    => ['caveman', 'git-guru'],  # enabled pack names
    );

Returns an L<App::Raider::Packs::Collection> containing the loaded packs.

=cut

sub _pack_defaults {
  my ($packs) = @_;
  my @defaults;

  for my $pack (values %$packs) {
    push @defaults, $pack->name if $pack->enabled_by_default;
  }

  my %seen_group;
  my @filtered;
  for my $name (@defaults) {
    my $pack = $packs->{$name};
    my $grp = $pack->exclusive_group;
    next if $grp eq 'power';
    unless ($seen_group{$grp}++) {
      push @filtered, $name;
    }
  }

  push @filtered, grep { $packs->{$_}->exclusive_group eq 'power' } @defaults;

  return \@filtered;
}

sub build_packs {
  my %args = @_;
  my $root = path($args{root} // '.')->absolute;

  my @search_paths;

  # Bundled share/packs/ discovery, in order of likelihood:
  #
  #   1. File::ShareDir when installed from CPAN (ShareDir plugin
  #      copies share/ into auto/share/dist/App-Raider/).
  #   2. Source-tree layout: $INC{App/Raider.pm} = lib/App/Raider.pm,
  #      sibling share/packs/ is three parents up after ->absolute.
  #   3. blib layout used by `dzil test` / `make test`:
  #      blib/lib/App/Raider.pm with share/packs/ one parent less.
  #   4. $RAIDER_PACK_DIRS env for explicit overrides.
  {
    my $sd = eval {
      File::ShareDir::dist_dir('App-Raider');
    };
    if ($sd) {
      my $p = path($sd)->child('packs');
      push @search_paths, $p if -d $p;
    }
  }

  my $mod_path = path($INC{'App/Raider.pm'})->absolute;
  for my $up (qw( parent_x3 parent_x2 )) {
    my $base = $up eq 'parent_x3'
      ? $mod_path->parent->parent->parent
      : $mod_path->parent->parent;
    my $cand = $base->child('share', 'packs');
    push @search_paths, $cand if -d $cand;
  }

  # $RAIDER_PACK_DIRS env
  if (my $env_dirs = $ENV{RAIDER_PACK_DIRS}) {
    for my $d (split /:/, $env_dirs) {
      my $p = path($d)->absolute;
      push @search_paths, $p if -d $p;
    }
  }

  my %packs_by_name;
  my %exclusive_groups;

  for my $sp (@search_paths) {
    next unless -d $sp;
    for my $pack_dir ($sp->children) {
      next unless -d $pack_dir;
      my $name = $pack_dir->basename;

      # Skip if already loaded (first-wins from search order)
      next if $packs_by_name{$name};

      my $yml_file = $pack_dir->child('pack.yml');
      my $skill_file = $pack_dir->child('SKILL.md');

      my $config = {};
      if (-f $yml_file) {
        $config = eval { YAML::PP->new->load_string($yml_file->slurp_utf8) } // {};
      }

      my $skill_text;
      $skill_text = $skill_file->slurp_utf8 if -f $skill_file;

      my $pack = App::Raider::Packs::Pack->new({
        name          => $name,
        path          => $pack_dir->stringify,
        skill_text    => $skill_text,
        exclusive_group => $config->{exclusive_group} // 'power',
        enabled_by_default => $config->{enabled_by_default} // 0,
        extra_mcp     => $config->{mcp} // [],
        add_allowed_commands => $config->{add_allowed_commands} // [],
        engine_options => $config->{engine_options} // {},
      });

      $packs_by_name{$name} = $pack;

      my $group = $pack->exclusive_group;
      push @{$exclusive_groups{$group}//=[]}, $name;
    }
  }

  # Build the collection with initial defaults
  return App::Raider::Packs::Collection->new({
    packs_by_name    => \%packs_by_name,
    exclusive_groups => \%exclusive_groups,
    _init_defaults   => _pack_defaults(\%packs_by_name),
  });
}

1;

package App::Raider::Packs::Pack;
our $VERSION = '0.004';

use Moose;
use namespace::autoclean;

has name          => (is => 'ro', isa => 'Str', required => 1);
has path          => (is => 'ro', isa => 'Str', required => 1);
has skill_text    => (is => 'ro', isa => 'Str', predicate => 'has_skill_text');
has exclusive_group => (is => 'ro', isa => 'Str', default => 'power');
has enabled_by_default => (is => 'ro', isa => 'Bool', default => 0);
has extra_mcp     => (is => 'ro', isa => 'ArrayRef', default => sub { [] });
has add_allowed_commands => (is => 'ro', isa => 'ArrayRef', default => sub { [] });
has engine_options => (is => 'ro', isa => 'HashRef', default => sub { {} });

__PACKAGE__->meta->make_immutable;

1;

package App::Raider::Packs::Collection;
our $VERSION = '0.004';

use Moose;
use namespace::autoclean;

has packs_by_name    => (is => 'ro', isa => 'HashRef', required => 1);
has exclusive_groups => (is => 'ro', isa => 'HashRef', required => 1);

# Enabled pack names for this session. Mutated in-place by enable/disable/toggle.
has enabled_pack_names => (
  is      => 'rw',
  isa     => 'ArrayRef',
  default => sub { [] },
);

# All pack names known
has all_pack_names => (
  is      => 'ro',
  isa     => 'ArrayRef',
  lazy    => 1,
  builder => '_build_all_pack_names',
);

sub BUILD {
  my ($self) = @_;
  my $init = $self->_init_defaults // [];
  my %active;
  my %seen_exclusive;

  for my $name (@$init) {
    my $pack = $self->packs_by_name->{$name} or next;
    my $grp = $pack->exclusive_group;

    if ($grp eq 'power') {
      $active{$name} = 1 unless $active{$name};
    }
    else {
      unless ($seen_exclusive{$grp}++) {
        $active{$name} = 1;
      }
    }
  }

  $self->enabled_pack_names([sort keys %active]);
}

has _init_defaults => (
  is      => 'ro',
  isa     => 'ArrayRef',
  default => sub { [] },
);

sub _build_all_pack_names {
  my ($self) = @_;
  return [sort keys %{$self->packs_by_name}];
}

=method enable

    $collection->enable('polite');   # enable polite (toggles off caveman)
    $collection->enable('git-guru');  # stack git-guru on top

=cut

sub enable {
  my ($self, $name) = @_;
  my $pack = $self->packs_by_name->{$name} or return;
  my $grp = $pack->exclusive_group;

  if ($grp eq 'power') {
    push @{$self->enabled_pack_names}, $name unless $self->_is_enabled($name);
  }
  else {
    # Exclusive group: remove others in same group first
    my @others = grep {
      my $p = $self->packs_by_name->{$_};
      $p && $p->exclusive_group eq $grp && $_ ne $name;
    } @{$self->enabled_pack_names};

    if (@others) {
      my %remove = map { $_ => 1 } @others;
      @{$self->enabled_pack_names} = grep { !$remove{$_} } @{$self->enabled_pack_names};
    }

    push @{$self->enabled_pack_names}, $name unless $self->_is_enabled($name);
  }

  return;
}

=method disable

    $collection->disable('caveman');
    $collection->disable('git-guru');

=cut

sub disable {
  my ($self, $name) = @_;
  my %remove = map { $_ => 1 } ($name);
  @{$self->enabled_pack_names} = grep { !$remove{$_} } @{$self->enabled_pack_names};
  return;
}

=method toggle

    $collection->toggle('polite');  # on if off, off if on

=cut

sub toggle {
  my ($self, $name) = @_;
  if ($self->_is_enabled($name)) {
    $self->disable($name);
  }
  else {
    $self->enable($name);
  }
}

sub _is_enabled {
  my ($self, $name) = @_;
  my %enabled = map { $_ => 1 } @{$self->enabled_pack_names};
  return $enabled{$name};
}

=method skill_texts

Returns the concatenated SKILL.md texts from all enabled packs.

=cut

sub skill_texts {
  my ($self) = @_;
  my @texts;
  for my $name (@{$self->enabled_pack_names}) {
    my $pack = $self->packs_by_name->{$name} or next;
    if ($pack->has_skill_text) {
      push @texts, "### Pack: $name\n\n" . $pack->skill_text;
    }
  }
  return @texts;
}

=method active_pack_names

Returns pack names that are currently enabled.

=cut

sub active_pack_names { $_[0]->enabled_pack_names }

=method is_active

    if ($collection->is_active('caveman')) { ... }

=cut

sub is_active { $_[0]->_is_enabled($_[1]) }

=method pack_info

    my $info = $collection->pack_info('caveman');
    # { name, exclusive_group, is_active, has_skill_text, path }

=cut

sub pack_info {
  my ($self, $name) = @_;
  my $pack = $self->packs_by_name->{$name} or return;
  return {
    name            => $pack->name,
    exclusive_group => $pack->exclusive_group,
    is_active       => $self->_is_enabled($name) ? JSON::MaybeXS::true : JSON::MaybeXS::false,
    has_skill_text  => $pack->has_skill_text ? JSON::MaybeXS::true : JSON::MaybeXS::false,
    path            => $pack->path,
  };
}

__PACKAGE__->meta->make_immutable;

1;
