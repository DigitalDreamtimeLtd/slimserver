package Slim::DataStores::DBI::DBIStore;

# $Id$

# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use base qw(Slim::DataStores::Base);

use DBI;
use File::Basename qw(dirname);
use List::Util qw(max);
use MP3::Info;
use Scalar::Util qw(blessed);
use Storable;
use Tie::Cache::LRU::Expires;

use Slim::DataStores::DBI::DataModel;

use Slim::DataStores::DBI::Album;
use Slim::DataStores::DBI::Contributor;
use Slim::DataStores::DBI::ContributorAlbum;
use Slim::DataStores::DBI::Genre;
use Slim::DataStores::DBI::LightWeightTrack;
use Slim::DataStores::DBI::Track;

use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Slim::Utils::Unicode;

# Save the persistant DB cache on an interval
my $DB_SAVE_INTERVAL = 30;

# cached value of commonAlbumTitles pref
our $common_albums;

# hold the current cleanup state
our $cleanupIds;
our $cleanupStage;

# Singleton objects for Unknowns
our ($_unknownArtist, $_unknownGenre, $_unknownAlbum) = ('', '', '');

# Keep the last 5 find results set in memory and expire them after 60 seconds
tie our %lastFind, 'Tie::Cache::LRU::Expires', EXPIRES => 60, ENTRIES => 5;

# Optimization to cache content type for track entries rather than look them up everytime.
tie our %contentTypeCache, 'Tie::Cache::LRU::Expires', EXPIRES => 300, ENTRIES => 128;

# Don't spike the CPU on cleanup.
our $staleCounter = 0;

# For the VA album merging & scheduler globals.
my ($variousAlbumIds, $vaObj);

# Abstract to the caller
my %typeToClass = (
	'artist' => 'Slim::DataStores::DBI::Contributor',
	'album'  => 'Slim::DataStores::DBI::Album',
	'track'  => 'Slim::DataStores::DBI::Track',
	'genre'  => 'Slim::DataStores::DBI::Genre',
);

#
# Readable DataStore interface methods:
#
sub new {
	my $class = shift;

	my $self = {
		# Values persisted in metainformation table
		trackCount => 0,
		totalTime => 0,
		# Non-persistent cache to make sure we don't set album artwork
		# too many times.
		artworkCache => {},
		# Non-persistent caches to store cover and thumb properties
		coverCache => {},
		thumbCache => {},
		# Optimization to cache last track accessed rather than retrieve it again. 
		lastTrackURL => '',
		lastTrack => {},
		# Tracks that are out of date and should be deleted the next time
		# we get around to it.
		zombieList => {},
	};

	bless $self, $class;

	Slim::DataStores::DBI::Track->setLoader($self);
	Slim::DataStores::DBI::DataModel->db_Main(1);
	
	($self->{'trackCount'}, $self->{'totalTime'}) = Slim::DataStores::DBI::DataModel->getMetaInformation();
	
	$self->_commitDBTimer();

	$common_albums = Slim::Utils::Prefs::get('commonAlbumTitles');

	Slim::Utils::Prefs::addPrefChangeHandler('commonAlbumTitles', \&commonAlbumTitlesChanged);

	return $self;
}

sub dbh {
	my $self = shift;

	return Slim::DataStores::DBI::DataModel->dbh;
}

sub driver {
	my $self = shift;

	return Slim::DataStores::DBI::DataModel->driver;
}

# SQLite has some tuning parameters available via it's PRAGMA interface. See
# http://www.sqlite.org/pragma.html for more details.
#
# These wrappers allow us to set the params.
sub modifyDatabaseTempStorage {
	my $self  = shift;
	my $value = shift || Slim::Utils::Prefs::get('databaseTempStorage');

	if ($self->driver eq 'SQLite') {

		eval { $self->dbh->do("PRAGMA temp_store = $value") };

		if ($@) {
			errorMsg("Couldn't change the database temp_store value to: [$value]: [$@]\n");
		}
	}
}

sub modifyDatabaseCacheSize {
	my $self  = shift;
	my $value = shift || Slim::Utils::Prefs::get('databaseCacheSize');

	if ($self->driver eq 'SQLite') {

		eval { $self->dbh->do("PRAGMA cache_size = $value") };

		if ($@) {
			errorMsg("Couldn't change the database cache_size value to: [$value]: [$@]\n");
		}
	}
}

sub classForType {
	my $self = shift;
	my $type = shift;

	return $typeToClass{$type};
}

sub contentType {
	my $self = shift;
	my $url  = shift;

	my $ct = 'unk';

	# Can't get a content type on a undef url
	unless (defined $url) {

		return wantarray ? ($ct) : $ct;
	}

	$ct = $contentTypeCache{$url};

	if (defined($ct)) {
		return wantarray ? ($ct, $self->_retrieveTrack($url)) : $ct;
	}

	my $track = $self->objectForUrl($url);

	# XXX - exception should go here. Comming soon.
	if (blessed($track) && $track->can('content_type')) {
		$ct = $track->content_type();
	} else {
		$ct = Slim::Music::Info::typeFromPath($url);
	}

	$contentTypeCache{$url} = $ct;

	return wantarray ? ($ct, $track) : $ct;
}

sub objectForUrl {
	my $self   = shift;
	my $url    = shift;
	my $create = shift;
	my $readTag = shift;
	my $lightweight = shift;

	# Confirm that the URL itself isn't an object (see bug 1811)
	# XXX - exception should go here. Comming soon.
	if (blessed($url) && blessed($url) =~ /Track/) {
		return $url;
	}

	if (!defined($url)) {
		msg("Null track request!\n"); 
		bt();
		return undef;
	}

	my $track = $self->_retrieveTrack($url, $lightweight);

	if (blessed($track) && $track->can('url') && !$create && !$lightweight) {
		$track = $self->_checkValidity($track);
	}

	# Handle the case where an object has been deleted out from under us.
	# XXX - exception should go here. Comming soon.
	if (blessed($track) && blessed($track) eq 'Class::DBI::Object::Has::Been::Deleted') {

		$track  = undef;
		$create = 1;
	}

	if (!defined $track && $create) {

		$track = $self->updateOrCreate({
			'url'      => $url,
			'readTags' => $readTag,
		});
	}

	return $track;
}

sub objectForId {
	my $self  = shift;
	my $field = shift;
	my $id    = shift;

	if ($field eq 'track' || $field eq 'playlist') {

		my $track = Slim::DataStores::DBI::Track->retrieve($id) || return;

		return $self->_checkValidity($track);

	} elsif ($field eq 'lightweighttrack') {

		return Slim::DataStores::DBI::LightWeightTrack->retrieve($id);

	} elsif ($field eq 'genre') {

		return Slim::DataStores::DBI::Genre->retrieve($id);

	} elsif ($field eq 'album') {

		return Slim::DataStores::DBI::Album->retrieve($id);

	} elsif ($field eq 'contributor' || $field eq 'artist') {

		return Slim::DataStores::DBI::Contributor->retrieve($id);
	}
}

sub find {
	my $self = shift;

	my $args = {};

	# Backwards compatibility with the previous calling method.
	if (scalar @_ > 1) {

		for my $key (qw(field find sortBy limit offset count)) {

			my $value = shift @_;

			$args->{$key} = $value if defined $value;
		}

	} else {

		$args = shift;
	}

	# If we're undefined for some reason - ie: We want all the results,
	# make sure that the ref type is correct.
	if (!defined $args->{'find'}) {
		$args->{'find'} = {};
	}

	# Only pull out items that are audio for a track search.
	if ($args->{'field'} && $args->{'field'} =~ /track$/) {

		$args->{'find'}->{'audio'} = 1;
	}

	# Try and keep the last result set in memory - so if the user is
	# paging through, we don't keep hitting the database.
	#
	# Can't easily use $limit/offset for the page bars, because they
	# require knowing the entire result set.
	my $findKey = Storable::freeze($args);

	#$::d_sql && msg("Generated findKey: [$findKey]\n");

	if (!defined $lastFind{$findKey} || (defined $args->{'cache'} && $args->{'cache'} == 0)) {

		# refcnt-- if we can, to prevent leaks.
		if ($Class::DBI::Weaken_Is_Available && !$args->{'count'}) {

			Scalar::Util::weaken($lastFind{$findKey} = Slim::DataStores::DBI::DataModel->find($args));

		} else {

			$lastFind{$findKey} = Slim::DataStores::DBI::DataModel->find($args);
		}

	} else {

		$::d_sql && msg("Used previous results for findKey\n");
	}

	my $items = $lastFind{$findKey};

	if (!$args->{'count'} && !$args->{'idOnly'} && defined($items) && $args->{'field'} =~ /track$/) {

		# Does the track still exist?
		if ($args->{'field'} ne 'lightweighttrack') {

			for (my $i = 0; $i < scalar @$items; $i++) {

				$items->[$i] = $self->_checkValidity($items->[$i]);
			}

			# Weed out any potential undefs
			@$items = grep { defined($_) } @$items;
		}
	}

	return $items if $args->{'count'};
	return wantarray() ? @$items : $items;
}

sub count {
	my $self  = shift;
	my $field = shift;
	my $find  = shift || {};

	# make a copy, because we might modify it below.
	my %findCriteria = %$find;

	if ($field eq 'artist') {
		$field = 'contributor';
	}

	# The user may not want to include all the composers / conductors
	#
	# But don't restrict if we have an album (this may be wrong) - 
	# for VA albums, we want the correct count.
	if ($field eq 'contributor' && !$findCriteria{'album'}) {

		if (my $roles = $self->artistOnlyRoles) {

			$findCriteria{'contributor.role'} = $roles;
		}

		if (Slim::Utils::Prefs::get('variousArtistAutoIdentification') && !exists $findCriteria{'album.compilation'}) {

			$findCriteria{'album.compilation'} = 0;
		}
	}

	# Optimize the all case
	if (scalar(keys %findCriteria) == 0) {

		if ($field eq 'track') {

			return $self->{'trackCount'};

		} elsif ($field eq 'genre') {

			return Slim::DataStores::DBI::Genre->count_all;

		} elsif ($field eq 'album') {

			return Slim::DataStores::DBI::Album->count_all;

		} elsif ($field eq 'contributor') {

			return Slim::DataStores::DBI::Contributor->count_all;
		}
	}

	return $self->find({
		'field' => $field,
		'find'  => \%findCriteria,
		'count' => 1,
	});
}

sub albumsWithArtwork {
	my $self = shift;
	
	return [ Slim::DataStores::DBI::Album->hasArtwork ];
}

sub totalTime {
	my $self = shift;

	return $self->{'totalTime'};
}

#
# Writeable DataStore interface methods:
#

# Update the track object in the database. The assumption is that
# attribute setter methods may already have been invoked on the
# object.
sub updateTrack {
	my ($self, $track, $commit) = @_;

	$track->update;

	$self->dbh->commit if $commit;
}

# Create a new track with the given attributes
sub newTrack {
	my $self = shift;
	my $args = shift;

	#
	my $url           = $args->{'url'};
 	my $attributeHash = $args->{'attributes'} || {};

	# Not sure how we can get here - but we can.
	if (!defined $url || ref($url)) {
	
		msg("newTrack: Bogus value for 'url'\n");
		require Data::Dumper;
		print Data::Dumper::Dumper($url);
		bt();

		return undef;
	}

	my $deferredAttributes;

	$::d_info && msg("New track for $url\n");

	# Default the tag reading behaviour if not explicitly set
	if (!defined $args->{'readTags'}) {
		$args->{'readTags'} = "default";
	}

	# Read the tag, and start populating the database.
	if ($args->{'readTags'}) {

		$::d_info && msg("readTag was ". $args->{'readTags'}  ." for $url\n");

		$attributeHash = { %{$self->readTags($url)}, %$attributeHash  };
	}

	($attributeHash, $deferredAttributes) = $self->_preCheckAttributes($url, $attributeHash, 1);

	# Creating the track only wants lower case values from valid columns.
	my $columnValueHash = {};

	my $trackAttrs = Slim::DataStores::DBI::Track::attributes();

	# Walk our list of valid attributes, and turn them into something ->create() can use.
	while (my ($key, $val) = each %$attributeHash) {

		if (defined $val && exists $trackAttrs->{lc $key}) {

			$::d_info && msg("Adding $url : $key to $val\n");

			$columnValueHash->{lc $key} = $val;
		}
	}

	# Tag and rename set URL to the Amazon image path. Smack that. We
	# don't use it anyways.
	$columnValueHash->{'url'} = $url;

	# Create the track - or bail. We should probably spew an error.
	my $track = eval { Slim::DataStores::DBI::Track->create($columnValueHash) };

	if ($@) {
		bt();
		msg("Couldn't create track for $url : $@\n");

		#require Data::Dumper;
		#print Data::Dumper::Dumper($columnValueHash);
		return;
	}

	# Now that we've created the track, and possibly an album object -
	# update genres, etc - that we need the track ID for.
	$self->_postCheckAttributes($track, $deferredAttributes, 1);

	if ($track->audio) {

		$self->{'lastTrackURL'} = $url;
		$self->{'lastTrack'}->{dirname($url)} = $track;

		my $time = $columnValueHash->{'secs'};

		if ($time) {
			$self->{'totalTime'} += $time;
		}

		$self->{'trackCount'}++;
	}

	$self->dbh->commit if $args->{'commit'};

	return $track;
}

# Update the attributes of a track or create one if one doesn't already exist.
sub updateOrCreate {
	my $self = shift;
	my $args = shift;

	#
	my $urlOrObj      = $args->{'url'};
	my $attributeHash = $args->{'attributes'} || {};
	my $commit        = $args->{'commit'};
	my $readTags      = $args->{'readTags'};

	# XXX - exception should go here. Comming soon.
	my $track = blessed($urlOrObj) ? $urlOrObj : undef;
	my $url   = blessed($track) && $track->can('url') ? $track->url : $urlOrObj;

	if (!defined($url)) {
		require Data::Dumper;
		print Data::Dumper::Dumper($attributeHash);
		msg("No URL specified for updateOrCreate\n");
		bt();
		return undef;
	}

	# Always remove from the zombie list, since we're about to update or
	# create this item.
	delete $self->{'zombieList'}->{$url};

	if (!blessed($track)) {
		$track = $self->_retrieveTrack($url);
	}

	my $trackAttrs = Slim::DataStores::DBI::Track::attributes();

	# XXX - exception should go here. Comming soon.
	if (blessed($track) && $track->can('url')) {

		$::d_info && msg("Merging entry for $url\n");

		# Force a re-read if requested.
		# But not for remote / non-audio files.
		# 
		# Bug: 2335 - readTags is set in Slim::Formats::Parse - when
		# we create/update a cue sheet to have a CT of 'cur'
		if ($readTags && $track->audio && !$track->remote && $attributeHash->{'CT'} ne 'cur') {

			$attributeHash = { %{$self->readTags($url)}, %$attributeHash  };
		}

		my $deferredAttributes;
		($attributeHash, $deferredAttributes) = $self->_preCheckAttributes($url, $attributeHash, 0);

		my %set = ();

		while (my ($key, $val) = each %$attributeHash) {

			if (defined $val && $val ne '' && exists $trackAttrs->{lc $key}) {

				$::d_info && msg("Updating $url : $key to $val\n");

				$set{$key} = $val;
			}
		}

		# Just make one call.
		$track->set(%set);

		$self->_postCheckAttributes($track, $deferredAttributes, 0);

		$self->updateTrack($track, $commit);

	} else {

		$track = $self->newTrack({
			'url'        => $url,
			'attributes' => $attributeHash,
			'readTags'   => $readTags,
			'commit'     => $commit,
		});
	}

	if ($attributeHash->{'CT'}) {
		$contentTypeCache{$url} = $attributeHash->{'CT'};
	}

	return $track;
}

# Delete a track from the database.
sub delete {
	my $self = shift;
	my $urlOrObj = shift;
	my $commit = shift;

	# XXX - exception should go here. Comming soon.
	my $track = blessed($urlOrObj) ? $urlOrObj : undef;
	my $url   = blessed($track) && $track->can('url') ? $track->url : $urlOrObj;

	if (!defined($track)) {
		$track = $self->_retrieveTrack($url);		
	}

	# XXX - exception should go here. Comming soon.
	if (blessed($track) && $track->can('url')) {

		# XXX - make sure that playlisttracks are deleted on cascade 
		# otherwise call $track->setTracks() with an empty list

		if ($track->audio) {

			$self->{'trackCount'}--;

			my $time = $track->get('secs');

			if ($time) {
				$self->{'totalTime'} -= $time;
			}
		}

		# Be sure to clear the track out of the cache as well.
		if ($url eq $self->{'lastTrackURL'}) {
			$self->{'lastTrackURL'} = '';
		}

		my $dirname = dirname($url);

		if (defined $self->{'lastTrack'}->{$dirname} && $self->{'lastTrack'}->{$dirname}->url eq $url) {
			delete $self->{'lastTrack'}->{$dirname};
		}

		$track->delete;

		$self->dbh->commit if $commit;

		$track = undef;

		$::d_info && msg("cleared $url from database\n");
	}
}

# Mark all track entries as being stale in preparation for scanning for validity.
sub markAllEntriesStale {
	my $self = shift;

	%lastFind         = ();
	%contentTypeCache = ();

	$self->{'artworkCache'} = {};
}

# Mark a track entry as valid.
sub markEntryAsValid {
	my $self = shift;
	my $url = shift;

	delete $self->{'zombieList'}->{$url};
}

# Mark a track entry as invalid.
# Does the reverse of above.
sub markEntryAsInvalid {
	my $self = shift;
	my $url  = shift || return undef;

	$self->{'zombieList'}->{$url} = 1;
}

sub cleanupStaleEntries {
	my $self = shift;

	# Setup a little state machine so that the db cleanup can be
	# scheduled appropriately - ie: one record per run.
	$::d_import && msg("Import: Adding task for cleanupStaleTrackEntries()..\n");

	Slim::Utils::Scheduler::add_task(\&cleanupStaleTrackEntries, $self);
}

# Clear all stale track entries.
sub cleanupStaleTrackEntries {
	my $self = shift;

	# Sun Mar 20 22:29:03 PST 2005
	# XXX - dsully - a lot of this is commented out, as myself
	# and Vidur decided that lazy track cleanup was best for now. This
	# means that if a user selects (via browsedb) a list of tracks which
	# is now longer there, it will be run through _checkValidity, and
	# marked as invalid. We still want to do Artist/Album/Genre cleanup
	# however.
	#
	# At Some Point in the Future(tm), Class::DBI should be modified, so
	# that retrieve_all() is lazy, and only fetches a $sth->row when
	# $obj->next is called.

	unless ($cleanupIds) {

		# Cleanup any stale entries in the database.
		# 
		# First walk the list of tracks, checking to see if the
		# file/directory/shortcut still exists on disk. If it doesn't, delete
		# it. This will cascade ::Track's has_many relationships, including
		# contributor_track, etc.
		#
		# After that, walk the Album, Contributor & Genre tables, to see if
		# each item has valid tracks still. If it doesn't, remove the object.

		$::d_import && msg("Import: Starting db garbage collection..\n");

		$cleanupIds = Slim::DataStores::DBI::Track->retrieveAllOnlyIds;
	}

	# Only cleanup every 20th time through the scheduler.
	$staleCounter++;
	return 1 if $staleCounter % 20;

	# fetch one at a time to keep memory usage in check.
	my $item  = shift(@{$cleanupIds});
	my $track = Slim::DataStores::DBI::Track->retrieve($item) if defined $item;

	# XXX - exception should go here. Comming soon.
	if (!blessed($track) && !defined $item && scalar @{$cleanupIds} == 0) {

		$::d_import && msg(
			"Import: Finished with stale track cleanup. Adding tasks for Contributors, Albums & Genres.\n"
		);

		$cleanupIds = undef;

		# Proceed with Albums, Genres & Contributors
		$cleanupStage = 'contributors';
		$staleCounter = 0;

		# Setup a little state machine so that the db cleanup can be
		# scheduled appropriately - ie: one record per run.
		Slim::Utils::Scheduler::add_task(\&cleanupStaleTableEntries, $self);

		return 0;
	};

	# Not sure how we get here, but we can. See bug 1756
	# XXX - exception should go here. Comming soon.
	if (!blessed($track) || !$track->can('url')) {
		return 1;
	}

	my $url = $track->url;

	# return 1 to move onto the next track
	unless (Slim::Music::Info::isFileURL($url)) {
		return 1;
	}
	
	my $filepath = Slim::Utils::Misc::pathFromFileURL($url);

	# Don't use _hasChanged - because that does more than we want.
	if (!-r $filepath) {

		$::d_import && msg("Import: Track $filepath no longer exists. Removing.\n");

		$self->delete($track, 1);
	}

	$track = undef;

	return 1;
}

# Walk the Album, Contributor and Genre tables to see if we have any dangling
# entries, pointing to non-existant tracks.
sub cleanupStaleTableEntries {
	my $self = shift;

	$staleCounter++;
	return 1 if $staleCounter % 20;

	if ($cleanupStage eq 'contributors') {

		unless (Slim::DataStores::DBI::Contributor->removeStaleDBEntries('contributorTracks')) {
			$cleanupStage = 'albums';
		}

		return 1;
	}

	if ($cleanupStage eq 'albums') {

		unless (Slim::DataStores::DBI::Album->removeStaleDBEntries('tracks')) {
			$cleanupStage = 'genres';
		}

		return 1;
	}

	if ($cleanupStage eq 'genres') {

		if (Slim::DataStores::DBI::Genre->removeStaleDBEntries('genreTracks')) {

			return 1;
		}
	}

	# We're done.
	$self->dbh->commit;

	$::d_import && msg("Import: Finished with cleanupStaleTableEntries()\n");

	%lastFind = ();

	$staleCounter = 0;
	return 0;
}

sub variousArtistsObject {
	my $self = shift;

	my $vaString = Slim::Music::Info::variousArtistString();

	# Fetch a VA object and/or update it's name if the user has changed it.
	# XXX - exception should go here. Comming soon.
	if (!blessed($vaObj) || !$vaObj->can('name')) {

		$vaObj  = Slim::DataStores::DBI::Contributor->find_or_create({
			'name' => $vaString,
		});
	}

	if ($vaObj && $vaObj->name ne $vaString) {

		$vaObj->name($vaString);
		$vaObj->namesort( Slim::Utils::Text::ignoreCaseArticles($vaString) );
		$vaObj->namesearch( Slim::Utils::Text::ignoreCaseArticles($vaString) );
		$vaObj->update;
	}

	return $vaObj;
}

# This is a post-process on the albums and contributor_tracks tables, in order
# to identify albums which are compilations / various artist albums - by
# virtue of having more than one artist.
sub mergeVariousArtistsAlbums {
        my $self = shift;

	unless ($variousAlbumIds) {

		$variousAlbumIds = Slim::DataStores::DBI::Album->retrieveAllOnlyIds;
	}

	# fetch one at a time to keep memory usage in check.
	my $item     = shift(@{$variousAlbumIds});
	my $albumObj = Slim::DataStores::DBI::Album->retrieve($item) if defined $item;

	# XXX - exception should go here. Comming soon.
	if (!blessed($albumObj) && !defined $item && scalar @{$variousAlbumIds} == 0) {

		$::d_import && msg("Import: Finished with mergeVariousArtistsAlbums()\n");

		$variousAlbumIds = ();

		return 0;
	}

	# XXX - exception should go here. Comming soon.
	if (!blessed($albumObj) || !$albumObj->can('tracks')) {
		$::d_import && msg("Import: mergeVariousArtistsAlbums: Couldn't fetch album for item: [$item]\n");
		return 0;
	}

	# This is a catch all - but don't mark it as VA.
	return 1 if $albumObj->title eq string('NO_ALBUM');

	# Don't need to process something we've already marked as a compilation.
	return 1 if $albumObj->compilation;

	my %trackArtists      = ();
	my $markAsCompilation = 0;

	for my $track ($albumObj->tracks) {

		# Bug 2066: If the user has an explict Album Artist set -
		# don't try to mark it as a compilation.
		for my $artist ($track->contributorsOfType('ALBUMARTIST')) {

			return 1;
		}

		# Create a composite of the artists for the track to compare below.
		my $artistComposite = join(':', sort map { $_->id } $track->contributorsOfType('ARTIST'));

		$trackArtists{$artistComposite} = 1;
	}

	# Bug 2418 - If the tracks have a hardcoded artist of 'Various Artists' - mark the album as a compilation.
	if (scalar values %trackArtists > 1) {

		$markAsCompilation = 1;

	} else {

		my ($artistId) = keys %trackArtists;

		if ($artistId == $self->variousArtistsObject->id) {

			$markAsCompilation = 1;
		}
	}

	if ($markAsCompilation) {

		$::d_import && msgf("Import: Marking album: [%s] as Various Artists.\n", $albumObj->title);

		$albumObj->compilation(1);
		$albumObj->update;
	}

	return 1;
}

sub wipeCaches {
	my $self = shift;

	$self->forceCommit;

	%contentTypeCache = ();
	%lastFind         = ();

	# clear the references to these singletons
	$vaObj            = undef;

	$self->{'artworkCache'} = {};
	$self->{'coverCache'}   = {};
	$self->{'thumbCache'}   = {};	
	$self->{'lastTrackURL'} = '';
	$self->{'lastTrack'}    = {};
	$self->{'zombieList'}   = {};

	Slim::DataStores::DBI::DataModel->clearObjectCaches;

	$::d_import && msg("Import: Wiped all in-memory caches.\n");
}

# Wipe all data in the database
sub wipeAllData {
	my $self = shift;

	$self->forceCommit;

	# clear the references to these singletons
	$_unknownArtist = '';
	$_unknownGenre  = '';
	$_unknownAlbum  = '';

	$self->{'totalTime'}    = 0;
	$self->{'trackCount'}   = 0;

	$self->wipeCaches;

	Slim::DataStores::DBI::DataModel->wipeDB;

	$::d_import && msg("Import: Wiped info database\n");
}

# Force a commit of the database
sub forceCommit {
	my $self = shift;

	# Update the track count
	Slim::DataStores::DBI::DataModel->setMetaInformation($self->{'trackCount'}, $self->{'totalTime'});

	for my $zombie (keys %{$self->{'zombieList'}}) {

		my ($track) = Slim::DataStores::DBI::Track->search('url' => $zombie);

		if ($track) {

			delete $self->{'zombieList'}->{$zombie};

			$self->delete($track, 0) if $track;
		}
	}

	$self->{'zombieList'} = {};
	$self->{'lastTrackURL'} = '';
	$self->{'lastTrack'} = {};

	$::d_info && msg("forceCommit: syncing to the database.\n");

	$self->dbh->commit;

	$Slim::DataStores::DBI::DataModel::dirtyCount = 0;

	# clear our find cache
	%lastFind = ();
}

sub clearExternalPlaylists {
	my $self = shift;
	my $url = shift;

	# We can specify a url prefix to only delete certain types of external
	# playlists - ie: only iTunes, or only MusicMagic.
	for my $track ($self->getPlaylists('external')) {

		# XXX - exception should go here. Comming soon.
		if (!blessed($track) || !$track->can('url')) {
			next;
		}

		$track->delete if (defined $url ? $track->url =~ /^$url/ : 1);
	}

	$self->forceCommit;
}

sub clearInternalPlaylists {
	my $self = shift;

	for my $track ($self->getPlaylists('internal')) {

		# XXX - exception should go here. Comming soon.
		if (!blessed($track) || !$track->can('delete')) {
			next;
		}

		$track->delete;
	}

	$self->forceCommit;
}

# Get the playlists
# param $type is 'all' for all playlists, 'internal' for internal playlists
# 'external' for external playlists. Default is 'all'.
# param $search is a search term on the playlist title.

sub getPlaylists {
	my $self = shift;
	my $type = shift || 'all';
	my $search = shift;

	my @playlists = ();
	
	if ($type eq 'all' || $type eq 'internal') {
		push @playlists, $Slim::Music::Info::suffixes{'playlist:'};
	}
	
	my $find = {};
	
	# Don't search for playlists if the plugin isn't enabled.
	if ($type eq 'all' || $type eq 'external') {
		for my $importer (qw(itunes moodlogic musicmagic)) {
	
			if (Slim::Utils::Prefs::get($importer)) {
	
				push @playlists, $Slim::Music::Info::suffixes{sprintf('%splaylist:', $importer)};
			}
		}
	}

	return () unless (scalar @playlists);

	# Add search criteria for playlists
	$find->{'ct'} = \@playlists;
		
	# Add title search if any
	$find->{'track.titlesearch'} = $search if (defined $search);
	
	return $self->find({
		'field'  => 'playlist',
		'find'   => $find,
		'sortBy' => 'title',
	});
}

sub getPlaylistForClient {
	my $self   = shift;
	my $client = shift;

	return (Slim::DataStores::DBI::Track->search({
		'url' => sprintf('clientplaylist://%s', $client->id())
	}))[0];
}

sub readTags {
	my $self  = shift;
	my $file  = shift;

	my ($filepath, $attributesHash, $anchor);

	if (!defined($file) || $file eq '') {
		return {};
	}

	$::d_info && msg("reading tags for: $file\n");

	if (Slim::Music::Info::isFileURL($file)) {
		$filepath = Slim::Utils::Misc::pathFromFileURL($file);
		$anchor   = Slim::Utils::Misc::anchorFromURL($file);
	} else {
		$filepath = $file;
	}

	# get the type without updating the cache
	my $type = Slim::Music::Info::typeFromPath($filepath);

	if (Slim::Music::Info::isSong($file, $type) && !Slim::Music::Info::isRemoteURL($file)) {

		# Extract tag and audio info per format
		if (exists $Slim::Music::Info::tagFunctions{$type}) {

			# Dynamically load the module in.
			if (!$Slim::Music::Info::tagFunctions{$type}->{'loaded'}) {
			
				Slim::Music::Info::loadTagFormatForType($type);
			}

			$attributesHash = eval { &{$Slim::Music::Info::tagFunctions{$type}->{'getTag'}}($filepath, $anchor) };
		}

		if ($@) {
			msg("The following error occurred: $@\n");
			bt();
		}

		$::d_info && !defined($attributesHash) && msg("Info: no tags found for $filepath\n");

		if (defined $attributesHash->{'TRACKNUM'}) {
			$attributesHash->{'TRACKNUM'} = Slim::Music::Info::cleanTrackNumber($attributesHash->{'TRACKNUM'});
		}
		
		# Turn the tag SET into DISC and DISCC if it looks like # or #/#
		if ($attributesHash->{'SET'} and $attributesHash->{'SET'} =~ /(\d+)(?:\/(\d+))?/) {

			# Strip leading 0s so that numeric compare at the db level works.
			$attributesHash->{'DISC'}  = int($1);
			$attributesHash->{'DISCC'} = int($2) if defined $2;
		}

		if (!$attributesHash->{'TITLE'}) {

			$::d_info && msg("Info: no title found, using plain title for $file\n");
			#$attributesHash->{'TITLE'} = Slim::Music::Info::plainTitle($file, $type);
			Slim::Music::Info::guessTags($file, $type, $attributesHash);
		}

		# fix the genre
		if (defined($attributesHash->{'GENRE'}) && $attributesHash->{'GENRE'} =~ /^\((\d+)\)$/) {
			# some programs (SoundJam) put their genres in as text digits surrounded by parens.
			# in this case, look it up in the table and use the real value...
			if (defined($MP3::Info::mp3_genres[$1])) {
				$attributesHash->{'GENRE'} = $MP3::Info::mp3_genres[$1];
			}
		}

		# Mark it as audio in the database.
		if (!defined $attributesHash->{'AUDIO'}) {

			$attributesHash->{'AUDIO'} = 1;
		}
	}

	# Last resort
	if (!defined $attributesHash->{'TITLE'} || $attributesHash->{'TITLE'} =~ /^\s*$/) {

		$::d_info && msg("Info: no title found, calculating title from url for $file\n");

		$attributesHash->{'TITLE'} = Slim::Music::Info::plainTitle($file, $type);
	}

	if (-e $filepath) {
		# cache the file size & date
		($attributesHash->{'FS'}, $attributesHash->{'AGE'}) = (stat($filepath))[7,9];
	}

	# Only set if we couldn't read it from the file.
	$attributesHash->{'CT'} ||= $type;

	# note that we've read in the tags.
	$attributesHash->{'TAG'} = 1;

	# Bug: 2381 - FooBar2k seems to add UTF8 boms to their values.
	while (my ($tag, $value) = each %{$attributesHash}) {

		$attributesHash->{$tag} = Slim::Utils::Unicode::stripBOM($value);
	}

	return $attributesHash;
}

sub setAlbumArtwork {
	my $self  = shift;
	my $track = shift;
	
	if (!Slim::Utils::Prefs::get('lookForArtwork')) {
		return undef
	}

	# XXX - exception should go here. Comming soon.
	if (!blessed($track) || !$track->can('album')) {
		return undef;
	}

	my $album    = $track->album();
	my $albumId  = $album->id() if $album;
	my $filepath = $track->url();

	# only cache albums once each
	if ($album && !exists $self->{'artworkCache'}->{$albumId}) {

		if (Slim::Music::Info::isFileURL($filepath)) {
			$filepath = Slim::Utils::Misc::pathFromFileURL($filepath);
		}

		$::d_artwork && msg("Updating $album artwork cache: $filepath\n");

		$self->{'artworkCache'}->{$albumId} = 1;

		$album->artwork_path($track->id);
		$album->update();
	}
}

# The user may want to constrain their browse view by either or both of
# 'composer' and 'track artists'.
sub artistOnlyRoles {
	my $self  = shift;

	my %roles = (
		'ARTIST'      => 1,
		'ALBUMARTIST' => 1,
	);

	# Loop through each pref to see if the user wants to show that contributor role.
	for my $role (qw(COMPOSER CONDUCTOR BAND)) {

		my $pref = sprintf('%sInArtists', lc($role));

		if (Slim::Utils::Prefs::get($pref)) {

			$roles{$role} = 1;
		}
	}

	# If we're using all roles, don't bother with the constraint.
	if (scalar keys %roles != Slim::DataStores::DBI::Contributor->totalContributorRoles) {

		return [ sort map { Slim::DataStores::DBI::Contributor->typeToRole($_) } keys %roles ];
	}

	return undef;
}

#
# Private methods:
#

sub _retrieveTrack {
	my $self = shift;
	my $url  = shift;
	my $lightweight = shift;

	return undef if ref($url);
	return undef if $self->{'zombieList'}->{$url};

	my $track;

	# Keep the last track per dirname.
	my $dirname = dirname($url);

	if ($url eq $self->{'lastTrackURL'}) {

		$track = $self->{'lastTrack'}->{$dirname};

	} elsif ($lightweight) {

		($track) = Slim::DataStores::DBI::LightWeightTrack->search('url' => $url);

	} else {

		# XXX - keep a url => id cache. so we can use the
		# live_object_index and not hit the db.
		($track) = Slim::DataStores::DBI::Track->search('url' => $url);
	}

	# XXX - exception should go here. Comming soon.
	if (blessed($track) && $track->can('audio') && $track->audio && !$lightweight) {

		$self->{'lastTrackURL'} = $url;
		$self->{'lastTrack'}->{$dirname} = $track;
	}

	return $track;
}

sub _commitDBTimer {
	my $self = shift;
	my $items = $Slim::DataStores::DBI::DataModel::dirtyCount;

	if ($items > 0) {
		$::d_info && msg("DBI: Periodic commit - $items dirty items\n");
		$self->forceCommit();
	} else {
		$::d_info && msg("DBI: Supressing periodic commit - no dirty items\n");
	}

	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + $DB_SAVE_INTERVAL, \&_commitDBTimer);
}

sub _checkValidity {
	my $self  = shift;
	my $track = shift;

	# XXX - exception should go here. Comming soon.
	return undef unless blessed($track);
	return undef unless $track->can('url');

	my $url = $track->url;

	return undef if $self->{'zombieList'}->{$url};

	$::d_info && msg("_checkValidity: Checking to see if $url has changed.\n");

	# Don't check for remote tracks, or things that aren't audio
	if ($track->audio && !$track->remote && $self->_hasChanged($track, $url)) {

		$::d_info && msg("_checkValidity: Re-reading tags from $url as it has changed.\n");

		# Do a cascading delete for has_many relationships - this will
		# clear out Contributors, Genres, etc.
		$track->call_trigger('before_delete');
		$track->update;

		$track = $self->updateOrCreate({
			'url'      => $track,
			'readTags' => 1,
			'commit'   => 1,
		});
	}

	return undef unless blessed($track);
	return undef unless $track->can('url');

	return $track;
}

sub _hasChanged {
	my ($self, $track, $url) = @_;

	# We return 0 if the file hasn't changed
	#    return 1 if the file has been changed.

	# Don't check anchors - only the top level file.
	return 0 if Slim::Utils::Misc::anchorFromURL($url);

	my $filepath = Slim::Utils::Misc::pathFromFileURL($url);

	$::d_info && msg("_hasChanged: Checking for [$filepath] - size & timestamp.\n");

	# Return if it's a directory - they expire themselves 
	# Todo - move directory expire code here?
	#return 0 if -d $filepath;
	return 0 if Slim::Music::Info::isDir($track);
	return 0 if Slim::Music::Info::isWinShortcut($track);

	# See if the file exists
	#
	# Reuse _, as we only need to stat() once.
	if (-e $filepath) {

		my $filesize  = $track->filesize();
		my $timestamp = $track->timestamp();

		# Check filesize and timestamp to decide if we use the cached data.
		my $fsdef   = (defined $filesize);
		my $fscheck = 0;

		if ($fsdef) {
			$fscheck = (-s _ == $filesize);
		}

		# Now the AGE
		my $agedef   = (defined $timestamp);
		my $agecheck = 0;

		if ($agedef) {
			$agecheck = ((stat(_))[9] == $timestamp);
		}

		return 0 if  $fsdef && $fscheck && $agedef && $agecheck;
		return 0 if  $fsdef && $fscheck && !$agedef;
		return 0 if !$fsdef && $agedef  && $agecheck;

		return 1;

	} else {

		$::d_info && msg("_hasChanged: removing [$filepath] from the db as it no longer exists.\n");

		$self->delete($track, 1);

		$track = undef;

		return 0;
	}
}

sub _preCheckAttributes {
	my $self = shift;
	my $url = shift;
 	my $attributeHash = shift;
 	my $create = shift;
	my $deferredAttributes = {};

	# Copy the incoming hash, so we don't modify it
	my $attributes = { %$attributeHash };

	# We also need these in _postCheckAttributes, but they should be set during create()
	$deferredAttributes->{'COVER'}   = $attributes->{'COVER'};
	$deferredAttributes->{'THUMB'}   = $attributes->{'THUMB'};
	$deferredAttributes->{'DISC'}    = $attributes->{'DISC'};
	
	# We've seen people with multiple TITLE tags in the wild.. why I don't
	# know. Merge them. Do the same for ALBUM, as you never know.
	for my $tag (qw(TITLE ALBUM)) {

		if ($attributes->{$tag} && ref($attributes->{$tag}) eq 'ARRAY') {

			$attributes->{$tag} = join(' / ', @{$attributes->{$tag}});
		}
	}

	if ($attributes->{'TITLE'} && !$attributes->{'TITLESORT'}) {
		$attributes->{'TITLESORT'} = $attributes->{'TITLE'};
	}

	if ($attributes->{'TITLE'} && $attributes->{'TITLESORT'}) {
		# Always normalize the sort, as TITLESORT could come from a TSOT tag.
		$attributes->{'TITLESORT'} = Slim::Utils::Text::ignoreCaseArticles($attributes->{'TITLESORT'});
	}

	# Create a canonical title to search against.
	$attributes->{'TITLESEARCH'} = Slim::Utils::Text::ignoreCaseArticles($attributes->{'TITLE'});

	# Remote index.
	$attributes->{'REMOTE'} = Slim::Music::Info::isRemoteURL($url) ? 1 : 0;

	# Munge the replaygain values a little
	for my $gainTag (qw(REPLAYGAIN_TRACK_GAIN REPLAYGAIN_TRACK_PEAK)) {

		my $shortTag = $gainTag;
		   $shortTag =~ s/^REPLAYGAIN_TRACK_(\w+)$/REPLAY_$1/;

		$attributes->{$shortTag} = delete $attributes->{$gainTag};
		$attributes->{$shortTag} =~ s/\s*dB//gi;
	}
			
	# Normalize ARTISTSORT in Contributor->add() the tag may need to be split. See bug #295
	#
	# Push these back until we have a Track object.
	for my $tag (qw(
		COMMENT BAND COMPOSER CONDUCTOR GENRE ARTIST ARTISTSORT 
		PIC APIC ALBUM ALBUMSORT DISCC ALBUMARTIST COMPILATION
		REPLAYGAIN_ALBUM_PEAK REPLAYGAIN_ALBUM_GAIN
		MUSICBRAINZ_ARTIST_ID MUSICBRAINZ_ALBUM_ARTIST_ID
		MUSICBRAINZ_ALBUM_ID MUSICBRAINZ_ALBUM_TYPE MUSICBRAINZ_ALBUM_STATUS
	)) {

		next unless defined $attributes->{$tag};

		$deferredAttributes->{$tag} = delete $attributes->{$tag};
	}

	return ($attributes, $deferredAttributes);
}

sub _postCheckAttributes {
	my $self = shift;
	my $track = shift;
	my $attributes = shift;
	my $create = shift;

	# XXX - exception should go here. Comming soon.
	if (!blessed($track) || !$track->can('get')) {
		return undef;
	}

	# Don't bother with directories / lnks. This makes sure "No Artist",
	# etc don't show up if you don't have any.
	if (Slim::Music::Info::isDir($track) || Slim::Music::Info::isWinShortcut($track)) {
		return undef;
	}

	my ($trackId, $trackUrl) = $track->get(qw(id url));

	# We don't want to add "No ..." entries for remote URLs, or meta
	# tracks like iTunes playlists.
	my $isLocal = Slim::Music::Info::isSong($track) && !Slim::Music::Info::isRemoteURL($track);

	# Genre addition. If there's no genre for this track, and no 'No Genre' object, create one.
	my $genre = $attributes->{'GENRE'};

	if ($create && $isLocal && !$genre && (!defined $_unknownGenre || ref($_unknownGenre) ne 'Slim::DataStores::DBI::Genre')) {

		$_unknownGenre = Slim::DataStores::DBI::Genre->find_or_create({
			'name'     => string('NO_GENRE'),
			'namesort' => Slim::Utils::Text::ignoreCaseArticles(string('NO_GENRE')),
		});

		Slim::DataStores::DBI::Genre->add($_unknownGenre, $track);

	} elsif ($create && $isLocal && !$genre) {

		Slim::DataStores::DBI::Genre->add($_unknownGenre, $track);

	} elsif ($create && $isLocal && $genre) {

		Slim::DataStores::DBI::Genre->add($genre, $track);

	} elsif (!$create && $isLocal && $genre && $genre ne $track->genre) {

		# Bug 1143: The user has updated the genre tag, and is
		# rescanning We need to remove the previous associations.
		for my $genreObj ($track->genres) {
			$genreObj->delete;
		}

		Slim::DataStores::DBI::Genre->add($genre, $track);
	}

	# Walk through the valid contributor roles, adding them to the database for each track.
	my $contributors     = $self->_mergeAndCreateContributors($track, $attributes);
	my $foundContributor = scalar keys %{$contributors};

	# Create a singleton for "No Artist"
	if ($create && $isLocal && !$foundContributor && !$_unknownArtist) {

		$_unknownArtist = Slim::DataStores::DBI::Contributor->find_or_create({
			'name'       => string('NO_ARTIST'),
			'namesort'   => Slim::Utils::Text::ignoreCaseArticles(string('NO_ARTIST')),
			'namesearch' => Slim::Utils::Text::ignoreCaseArticles(string('NO_ARTIST')),
		});

		Slim::DataStores::DBI::Contributor->add(
			$_unknownArtist,
			Slim::DataStores::DBI::Contributor->typeToRole('ARTIST'),
			$track
		);

		push @{ $contributors->{'ARTIST'} }, $_unknownArtist;

	} elsif ($create && $isLocal && !$foundContributor) {

		# Otherwise - reuse the singleton object, since this is the
		# second time through.
		Slim::DataStores::DBI::Contributor->add(
			$_unknownArtist,
			Slim::DataStores::DBI::Contributor->typeToRole('ARTIST'),
			$track
		);

		push @{ $contributors->{'ARTIST'} }, $_unknownArtist;
	}

	# The "primary" contributor
	my $contributor = ($contributors->{'ALBUMARTIST'}->[0] || $contributors->{'ARTIST'}->[0]);

	# Now handle Album creation
	my $album    = $attributes->{'ALBUM'};
	my $disc     = $attributes->{'DISC'};
	my $discc    = $attributes->{'DISCC'};

	# we may have an album object already..
	my $albumObj = $track->album if !$create;
	
	# Create a singleton for "No Album"
	# Album should probably have an add() method
	if ($create && $isLocal && !$album && !$_unknownAlbum) {

		$_unknownAlbum = Slim::DataStores::DBI::Album->find_or_create({
			'title'       => string('NO_ALBUM'),
			'titlesort'   => Slim::Utils::Text::ignoreCaseArticles(string('NO_ALBUM')),
			'titlesearch' => Slim::Utils::Text::ignoreCaseArticles(string('NO_ALBUM')),
		});

		$track->album($_unknownAlbum);
		$albumObj = $_unknownAlbum;

	} elsif ($create && $isLocal && !$album && blessed($_unknownAlbum)) {

		$track->album($_unknownAlbum);
		$albumObj = $_unknownAlbum;

	} elsif ($create && $isLocal && $album) {

		# Used for keeping track of the album name.
		my $basename = dirname($trackUrl);
		
		# Calculate once if we need/want to test for disc
		# Check only if asked to treat discs as separate and
		# if we have a disc, provided we're not in the iTunes situation (disc == discc == 1)
		my $checkDisc = 0;

		if (!Slim::Utils::Prefs::get('groupdiscs') && 
			(($disc && $discc && $discc > 1) || ($disc && !$discc))) {

			$checkDisc = 1;
		}

		# Go through some contortions to see if the album we're in
		# already exists. Because we keep contributors now, but an
		# album can have many contributors, check the disc and
		# album name, to see if we're actually the same.
		
		# For some reason here we do not apply the same criterias as below:
		# Path, compilation, etc are ignored...

		if (
			$self->{'lastTrack'}->{$basename} && 
			$self->{'lastTrack'}->{$basename}->album &&
			blessed($self->{'lastTrack'}->{$basename}->album) eq 'Slim::DataStores::DBI::Album' &&
			$self->{'lastTrack'}->{$basename}->album->get('title') eq $album &&
			(!$checkDisc || ($disc eq $self->{'lastTrack'}->{$basename}->album->disc))

			) {

			$albumObj = $self->{'lastTrack'}->{$basename}->album;

			$::d_info && msg("_postCheckAttributes: Same album '$album' than previous track\n");

		} else {

			# Don't use year as a search criteria. Compilations in particular
			# may have different dates for each track...
			# If re-added here then it should be checked also above, otherwise
			# the server behaviour changes depending on the track order!
			# Maybe we need a preference?
			my $search = {
				'title' => $album,
				#'year'  => $track->year,
			};

			# Add disc to the search criteria if needed
			if ($checkDisc) {

				$search->{'disc'} = $disc;
			}

			# If we have a compilation bit set - use that instead
			# of trying to match on the artist. Having the
			# compilation bit means that this is 99% of the time a
			# Various Artist album, so a contributor match would fail.
			if (defined $attributes->{'COMPILATION'}) {

				$search->{'compilation'} = $attributes->{'COMPILATION'};

			} else {

				# Check if the album name is one of the "common album names"
				# we've identified in prefs. If so, we require a match on
				# both album name and primary artist name.
				my $commonAlbumTitlesToggle = Slim::Utils::Prefs::get('commonAlbumTitlesToggle');

				if ($commonAlbumTitlesToggle && (grep $album =~ m/^$_$/i, @$common_albums)) {

					$search->{'contributor'} = $contributor;
				}
			}

			($albumObj) = eval { Slim::DataStores::DBI::Album->search($search) };

			$::d_info && msg("_postCheckAttributes: Searched for album '$album'\n") if $albumObj;

			if ($@) {
				msg("_postCheckAttributes: There was an error searching for an album match!\n");
				msg("_postCheckAttributes: Error message: [$@]\n");
				require Data::Dumper;
				print Data::Dumper::Dumper($search);
			}

			# We've found an album above - and we're not looking
			# for a multi-disc or compilation album, check to see
			# if that album already has a track number that
			# corresponds to our current working track and that
			# the other track is not in our current directory. If
			# so, then we need to create a new album. If not, the
			# album object is valid.
			if ($albumObj && $checkDisc && !$attributes->{'COMPILATION'}) {

				my %tracks     = map { $_->tracknum, $_ } $albumObj->tracks;
				my $matchTrack = $tracks{ $track->tracknum };

				if (defined $matchTrack && dirname($matchTrack->url) ne dirname($track->url)) {

					$albumObj = undef;

					$::d_info && msg("_postCheckAttributes: Wrong album '$album' found\n");
				}
			}

			# Didn't match anything? It's a new album - create it.
			if (!$albumObj) {
				
				$::d_info && msg("_postCheckAttributes: Creating album '$album'\n");

				$albumObj = Slim::DataStores::DBI::Album->create({ 
					title => $album,
				});
			}
		}

		# Associate cover art with this album, and keep it cached.
		unless ($self->{'artworkCache'}->{$albumObj->id}) {

			if (!Slim::Music::Import::artwork($albumObj) && !defined $track->thumb()) {

				Slim::Music::Import::artwork($albumObj, $track);
			}
		}
	}

	if (defined($album) && blessed($albumObj) && $albumObj->can('title') && ($albumObj ne $_unknownAlbum)) {

		my $sortable_title = Slim::Utils::Text::ignoreCaseArticles($attributes->{'ALBUMSORT'} || $album);

		# Add an album artist if it exists.
		$albumObj->contributor($contributor) if blessed($contributor);

		# Always normalize the sort, as ALBUMSORT could come from a TSOA tag.
		$albumObj->titlesort($sortable_title);

		# And our searchable version.
		$albumObj->titlesearch(Slim::Utils::Text::ignoreCaseArticles($album));

		# Bug 2393 - Check for 'no' instead of just true or false
		if ($attributes->{'COMPILATION'} && $attributes->{'COMPILATION'} !~ /no/i) {

			$albumObj->compilation(1);

		} else {

			$albumObj->compilation(0);
		}

		$albumObj->musicbrainz_id($attributes->{'MUSICBRAINZ_ALBUM_ID'});

		# Handle album gain tags.
		for my $gainTag (qw(REPLAYGAIN_ALBUM_GAIN REPLAYGAIN_ALBUM_PEAK)) {

			my $shortTag = lc($gainTag);
			   $shortTag =~ s/^replaygain_album_(\w+)$/replay_$1/;

			if ($attributes->{$gainTag}) {

				$attributes->{$gainTag} =~ s/\s*dB//gi;

				$albumObj->set($shortTag, $attributes->{$gainTag});

			} else {

				$albumObj->set($shortTag, undef);
			}
		}

		# Make sure we have a good value for DISCC if grouping
		# or if one is supplied
		if (Slim::Utils::Prefs::get('groupdiscs') || $discc) {
			$discc = max($disc, $discc, $albumObj->discc);
		}

		$albumObj->disc($disc);
		$albumObj->discc($discc);
		$albumObj->year($track->year);
		$albumObj->update;

		# Don't add an album to container tracks - See bug 2337
		if (!Slim::Music::Info::isContainer($track)) {

			$track->album($albumObj);
		}

		# Now create a contributors <-> album mapping
		if (!$create) {

			# Did the user change the album title?
			if ($albumObj->title ne $album) {

				$albumObj->set('title', $album);
			}

			# Remove all the previous mappings
			Slim::DataStores::DBI::ContributorAlbum->search('album' => $albumObj)->delete_all;

			$albumObj->update;
		}

		while (my ($role, $contributors) = each %{$contributors}) {

			for my $contributor (@{$contributors}) {

				Slim::DataStores::DBI::ContributorAlbum->find_or_create({
					album       => $albumObj,
					contributor => $contributor,
					role        => Slim::DataStores::DBI::Contributor->typeToRole($role),
				});
			}
		}
	}

	# Compute a compound sort key we'll use for queries that involve
	# multiple albums. Rather than requiring a multi-way join to get
	# all the individual sort keys from different tables, this is an
	# optimization that only requires the tracks table.
	$albumObj ||= $track->album();

	my ($albumName, $primaryContributor) = ('', '');

	if (blessed($albumObj) && $albumObj->can('titlesort')) {
		$albumName = $albumObj->titlesort;
	}

	# Find a contributor associated with this track.
	if (blessed($contributor) && $contributor->can('namesort')) {

		$primaryContributor = $contributor->namesort;

	} elsif (blessed($albumObj) && $albumObj->can('contributor')) {

		$contributor = $albumObj->contributor;

		if (blessed($contributor) && $contributor->can('namesort')) {

			$primaryContributor = $contributor->namesort;
		}
	}

	# Save 2 get calls
	my ($titlesort, $tracknum) = $track->get(qw(titlesort tracknum));

	my @keys = ();

	push @keys, $primaryContributor || '';
	push @keys, $albumName || '';
	push @keys, $disc if defined($disc);
	push @keys, sprintf("%03d", $tracknum) if defined $tracknum;
	push @keys, $titlesort || '';

	$track->multialbumsortkey(join ' ', @keys);
	$track->update();

	# Add comments if we have them:
	# We can take an array too - from vorbis comments, so be sure to handle that.
	my $comments = [];

	if ($attributes->{'COMMENT'} && !ref($attributes->{'COMMENT'})) {

		$comments = [ $attributes->{'COMMENT'} ];

	} elsif (ref($attributes->{'COMMENT'}) eq 'ARRAY') {

		$comments = $attributes->{'COMMENT'};
	}

	for my $comment (@$comments) {

		Slim::DataStores::DBI::Comment->find_or_create({
			'track' => $trackId,
			'value' => $comment,
		});
	}

	# refcount--
	%{$contributors} = ();
}

sub _mergeAndCreateContributors {
	my ($self, $track, $attributes) = @_;

	my %contributors = ();

	# XXXX - This order matters! Album artist should always be first,
	# since we grab the 0th element from the contributors array below when
	# creating the Album.
	my @tags = qw(ALBUMARTIST ARTIST BAND COMPOSER CONDUCTOR);

	for my $tag (@tags) {

		my $contributor = $attributes->{$tag} || next;

		# Is ARTISTSORT/TSOP always right for non-artist
		# contributors? I think so. ID3 doesn't have
		# "BANDSORT" or similar at any rate.
		push @{ $contributors{$tag} }, Slim::DataStores::DBI::Contributor->add(
			$contributor, 
			$attributes->{"MUSICBRAINZ_${tag}_ID"},
			Slim::DataStores::DBI::Contributor->typeToRole($tag),
			$track,
			$attributes->{$tag.'SORT'},
		);
	}

	return \%contributors;
}

sub updateCoverArt {
	my $self     = shift;
	my $fullpath = shift;
	my $type     = shift || 'cover';

	# Check if we've already attempted to get artwork this session
	if (($type eq 'cover') && defined($self->{'coverCache'}->{$fullpath})) {

		return;

	} elsif (($type eq 'thumb') && defined($self->{'thumbCache'}->{$fullpath})) {

		return;
	}
			
	my ($body, $contenttype, $path) = Slim::Music::Info::readCoverArt($fullpath, $type);

 	if (defined($body)) {

		my $info = {};

 		if ($type eq 'cover') {

 			$info->{'COVER'} = $path;
 			$info->{'COVERTYPE'} = $contenttype;
			$self->{'coverCache'}->{$fullpath} = $path;

 		} elsif ($type eq 'thumb') {

 			$info->{'THUMB'} = $path;
 			$info->{'THUMBTYPE'} = $contenttype;
			$self->{'thumbCache'}->{$fullpath} = $path;
 		}

 		$::d_artwork && msg("$type caching $path for $fullpath\n");

		$self->updateOrCreate({
			'url'        => $fullpath,
			'attributes' => $info
		});

 	} else {

		if ($type eq 'cover') {
			$self->{'coverCache'}->{$fullpath} = 0;
 		} elsif ($type eq 'thumb') {
			$self->{'thumbCache'}->{$fullpath} = 0;
 		}
 	}
}

# This is a callback that is run when the user changes the common album titles
# preference in settings.
sub commonAlbumTitlesChanged {
	my ($value, $key, $index) = @_;

	# Add the new value, or splice it out.
	if ($value) {

		$common_albums->[$index] = $value;

	} else {

		splice @$common_albums, $index, 1;
	}
}

1;

__END__


# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
