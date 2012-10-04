package EnsEMBL::REST::Controller::Sequence;

use Moose;
use namespace::autoclean;

use Try::Tiny;
require EnsEMBL::REST;

BEGIN { extends 'Catalyst::Controller::REST'; }

__PACKAGE__->config(
  map => {
    'text/html'           => [qw/View FASTAHTML/],
    'text/plain'          => [qw/View SequenceText/],
    'text/x-fasta'        => [qw/View FASTAText/],
    'text/x-seqxml+xml'   => [qw/View SeqXML/],
  }
);
EnsEMBL::REST->turn_on_jsonp(__PACKAGE__);

my %allowed_values = (
  type    => { map { $_, 1} qw(cds cdna genomic)},
  mask    => { map { $_, 1} qw(soft hard) },
);

sub id_GET { }

sub id :Path('id') Args(1) ActionClass('REST') {
  my ($self, $c, $stable_id) = @_;
  $c->stash->{id} = $stable_id;
  
  try {
    $c->log()->debug('Finding the object');
    $c->model('Lookup')->find_object_by_stable_id($c, $c->stash()->{id});
    $c->log()->debug('Processing the sequences');
    $self->_process($c);
    $c->log()->debug('Pushing out the entity');
    $self->_write($c);
  } catch {
    $c->go('ReturnError', 'from_ensembl', [$_]);
  };
  return;
}

sub region_GET { }

sub get_species :Chained('/') PathPart('sequence/region') CaptureArgs(1) {
  my ($self, $c, $species) = @_;
  $c->stash()->{species} = $species;
}

sub region :Chained('get_species') PathPart('') Args(1) ActionClass('REST') {
  my ($self, $c, $region) = @_;
  
  try {
    $c->log()->debug('Finding the Slice');
    my $slice = $c->model('Lookup')->find_slice($c, $region);
    $slice = $self->_enrich_slice($c, $slice);
    $c->log()->debug('Producing the sequence');
    my $seq = $slice->seq();
    $c->stash()->{seq_ref} = \$seq;
    $c->stash()->{molecule} = 'dna';
    $c->stash()->{id} = $slice->name();
    $c->log()->debug('Pushing out the entity');
    $self->_write($c);
  } catch {
    $c->go('ReturnError', 'from_ensembl', [$_]);
  };
  return;
}

sub _process {
  my ($self, $c) = @_;
  my $s = $c->stash();
  my $object = $s->{object};
  my $ref = ref($object);
  my $type = $c->request()->param('type');

  my $seq;
  my $slice;
  my $molecule = 'dna';

  #Translations
  if($object->isa('Bio::EnsEMBL::Translation')) {
    $molecule = 'protein';
    $seq = $object->transcript()->translate()->seq();
  }
  #Transcripts
  elsif($object->isa('Bio::EnsEMBL::Transcript')) {
    if($type eq 'cdna') {
      $seq = $object->spliced_seq();
    }
    elsif($type eq 'cds') {
      $seq = $object->translateable_seq();
    }
    elsif($type eq 'protein') {
      $seq = $object->translate()->seq();
      $molecule = 'protein';
    }
    else {
      $slice = $object->feature_Slice();
    }
  }
  # Anything else
  else {
    $slice = $object->feature_Slice();
  }
  
  if($slice) {
    $slice = $self->_enrich_slice($c, $slice);
    $seq = $slice->seq();
    $s->{desc} = $slice->name();
  }

  $s->{seq_ref} = \$seq;
  $s->{molecule} = $molecule;
}

sub _enrich_slice {
  my ($self, $c, $slice) = @_;
  $slice = $self->_expand_slice($c, $slice);
  $slice = $self->_mask_slice($c, $slice);
  $self->assert_slice_length($c, $slice);
  return $slice;
}

sub _expand_slice {
  my ($self, $c, $slice) = @_;
  my $five = $c->request()->param('expand_5prime') || 0;
  my $three = $c->request()->param('expand_3prime') || 0;
  if($five || $three) {
    return $slice->expand($five, $three);
  }
  return $slice;
}

sub _mask_slice {
  my ($self, $c, $slice) = @_;
  my $mask = $c->request()->param('mask') || q{};
  my $soft_mask = ($mask eq 'soft') ? 1 : 0;
  if($mask) {
    $c->go('ReturnError', 'custom', ["'$mask' is not an allowed value for masking"]) unless $allowed_values{mask}{$mask};
    return $slice->get_repeatmasked_seq(undef, $soft_mask);
  }
  return $slice;
}

sub _write {
  my ($self, $c) = @_;
  my $s = $c->stash();
  $self->status_ok(
    $c, entity => { seq => ${$s->{seq_ref}}, id => $s->{id}, molecule => $s->{molecule}, desc => $s->{desc} }
  );
}

sub default_length {
  return 1e7;
}

sub length_config_key {
  return 'Sequence';
}

with 'EnsEMBL::REST::Role::SliceLength';
with 'EnsEMBL::REST::Role::Content';

__PACKAGE__->meta->make_immutable;

1;

