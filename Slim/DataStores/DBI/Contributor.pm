package Slim::DataStores::DBI::Contributor;

# $Id$

use strict;
use base 'Slim::DataStores::DBI::DataModel';
use Scalar::Util qw(blessed);

our %contributorToRoleMap = (
	'ARTIST'      => 1,
	'COMPOSER'    => 2,
	'CONDUCTOR'   => 3,
	'BAND'        => 4,
	'ALBUMARTIST' => 5,
);

{
	my $class = __PACKAGE__;

	$class->table('contributors');

	$class->columns(Primary => qw/id/);

	$class->columns(Essential => qw/name namesort moodlogic_id moodlogic_mixable musicmagic_mixable/);

	$class->columns(Others => qw/namesearch musicbrainz_id/);

	$class->columns(Stringify => qw/name/);

	$class->has_many('contributorTracks' => ['Slim::DataStores::DBI::ContributorTrack' => 'contributor']);
}

sub contributorRoles {
	my $class = shift;

	return keys %contributorToRoleMap;
}

sub totalContributorRoles {
	my $class = shift;

	return scalar keys %contributorToRoleMap;
}

sub typeToRole {
	my $class = shift;
	my $type  = shift;

	return $contributorToRoleMap{$type};
}

sub add {
	my $class      = shift;
	my $artist     = shift;
	my $brainzID   = shift;
	my $role       = shift;
	my $track      = shift;
	my $artistSort = shift || $artist;

	my @contributors = ();

	# Dynamically determine the constructor if we need to force object creation.
	my $createMethod = 'find_or_create';

	# Bug 1955 - Previously 'last one in' would win for a
	# contributorTrack - ie: contributor & role combo, if a track
	# had an ARTIST & COMPOSER that were the same value.
	#
	# If we come across that case, force the creation of a second
	# contributorTrack entry.
	#
	# Split both the regular and the normalized tags
	my @artistList   = Slim::Music::Info::splitTag($artist);
	my @sortedList   = Slim::Music::Info::splitTag($artistSort);

	if ($role =~ /file/) {
		Slim::Utils::Misc::bt();
	}

	for (my $i = 0; $i < scalar @artistList; $i++) {

		# The search columnn is the canonical text that we match against in a search.
		my $name   = $artistList[$i];
		my $search = Slim::Utils::Text::ignoreCaseArticles($name);
		my $sort   = Slim::Utils::Text::ignoreCaseArticles(($sortedList[$i] || $name));

		my ($contributorObj) = Slim::DataStores::DBI::Contributor->search({
			'namesearch' => $search,
		});

		if ($contributorObj) {

			my ($contributorTrackObj) = Slim::DataStores::DBI::ContributorTrack->search({
				'contributor' => $contributorObj,
				'role'        => $role,
				'track'       => $track,
			});

			# This combination already exists in the db - don't re(create) it.
			if (defined $contributorTrackObj) {
				next;
			}

			$createMethod = 'create';

		} else {

			$contributorObj = Slim::DataStores::DBI::Contributor->create({ 
				namesearch => $search,
			});
		}

		$contributorObj->name($name);
		$contributorObj->namesort($sort);
		$contributorObj->musicbrainz_id($brainzID);
		$contributorObj->update;

		push @contributors, $contributorObj;

		# Create a contributor <-> track mapping table.
		my $contributorTrack = Slim::DataStores::DBI::ContributorTrack->$createMethod({
			track       => $track,
			contributor => $contributorObj,
			namesort    => $sort,
		});

		$contributorTrack->role($role);
		$contributorTrack->update;
	}

	return wantarray ? @contributors : $contributors[0];
}

1;

__END__


# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
