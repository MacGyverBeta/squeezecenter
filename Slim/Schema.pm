package Slim::Schema;

# $Id: Schema.pm 31756 2011-01-14 22:04:14Z agrundman $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Schema

=head1 SYNOPSIS

my $track = Slim::Schema->objectForUrl($url);

=head1 DESCRIPTION

L<Slim::Schema> is the main entry point for all interactions with Squeezebox Server's
database backend. It provides an ORM abstraction layer on top of L<DBI>,
acting as a subclass of L<DBIx::Class::Schema>.

=cut

use strict;
use warnings;

use base qw(DBIx::Class::Schema);

use DBIx::Migration;
use File::Basename qw(basename dirname);
use File::Copy qw(move);
use File::Spec::Functions qw(:ALL);
use List::Util qw(max);
use Path::Class;
use Scalar::Util qw(blessed);
use Storable;
use Tie::Cache::LRU::Expires;
use URI;

use Slim::Formats;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::SQLHelper;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Slim::Utils::Unicode;
use Slim::Utils::Progress;
use Slim::Utils::Prefs;
use Slim::Schema::Debug;

use Slim::Schema::RemoteTrack;
use Slim::Schema::RemotePlaylist;

my $log = logger('database.info');

my $prefs = preferences('server');

# Singleton objects for Unknowns
our ($_unknownArtist, $_unknownGenre, $_unknownAlbum) = ('', '', '');

my $sqlHelperClass = Slim::Utils::OSDetect->getOS()->sqlHelperClass();

# Optimization to cache content type for track entries rather than look them up everytime.
tie our %contentTypeCache, 'Tie::Cache::LRU::Expires', EXPIRES => 300, ENTRIES => 128;

# For the VA album merging & scheduler globals.
my ($variousAlbumIds, $vaObj);

# Map the tags we get from metadata onto the database
my %tagMapping = (
	'size'       => 'audio_size',
	'offset'     => 'audio_offset',
	'rate'       => 'samplerate',
	'age'        => 'timestamp',
	'ct'         => 'content_type',
	'fs'         => 'filesize',
	'blockalign' => 'block_alignment',
);

# will be built in init using _buildValidHierarchies
my %validHierarchies = ();

our $initialized         = 0;
my $trackAttrs           = {};
my $trackPersistentAttrs = {};

my %ratingImplementations = (
	'LOCAL_RATING_STORAGE' => \&_defaultRatingImplementation,
);

# Track the last error during scanning
my $LAST_ERROR = 'Unknown Error';

# Cache the basic top-level ResultSet objects
my %RS_CACHE = ();

# Cache library totals
my %TOTAL_CACHE = ();

=head1 METHODS

All methods below are class methods on L<Slim::Schema>. Please see
L<DBIx::Class::Schema> for methods on the superclass.

=head2 init( )

Connect to the database as defined by dbsource, dbusername & dbpassword in the
prefs file. Set via L<Slim::Utils::Prefs>.

This method will also initialize the schema to the current version, and
automatically upgrade older versions to the most recent.

Must be called before any other actions. Generally from L<Slim::Music::Info>

=cut

sub init {
	my ( $class, $dsn, $sql ) = @_;
	
	return if $initialized;
	
	my $dbh = $class->_connect($dsn, $sql) || do {

		# Not much we can do if there's no DB.
		logBacktrace("Couldn't connect to database! Fatal error: [$!] Exiting!");
		exit;
	};

	# Bug: 4076
	# If a user was using MySQL with 6.3.x (unsupported), their
	# metainformation table won't be dropped with the schema_1_up.sql
	# file, since the metainformation table doesn't get dropped to
	# maintain state. We need to wipe the DB and start over.
	eval {
		local $dbh->{HandleError} = sub {};
		$dbh->do('SELECT name FROM metainformation') || die $dbh->errstr;
	};

	# If we couldn't select our new 'name' column, then drop the
	# metainformation (and possibly dbix_migration, if the db is in a
	# wierd state), so that the migrateDB call below will update the schema.
	if ( $@ && !main::SLIM_SERVICE ) {
		logWarning("Creating new database - empty database or database from 6.3.x found");

		eval {
			$dbh->do('DROP TABLE IF EXISTS metainformation');
			$dbh->do('DROP TABLE IF EXISTS dbix_migration');
		}
	}

	my $update;
	
	if ( main::SLIM_SERVICE ) {
		$update = 1;
	}
	else {
		$update = $class->migrateDB;
	}

	# Load the DBIx::Class::Schema classes we've defined.
	# If you add a class to the schema, you must add it here as well.
	if ( main::SLIM_SERVICE ) {
		$class->load_classes(qw/
			Playlist
			PlaylistTrack
			Track
		/);
	}
	else {
		$class->load_classes(qw/
			Age
			Album
			Comment
			Contributor
			ContributorAlbum
			ContributorTrack
			Genre
			GenreTrack
			MetaInformation
			Playlist
			PlaylistTrack
			Rescan
			Track
			TrackPersistent
			Year
			Progress
		/);
	}

	# Build all our class accessors and populate them.
	for my $accessor (qw(lastTrackURL lastTrack trackAttrs trackPersistentAttrs driver schemaUpdated)) {

		$class->mk_classaccessor($accessor);
	}

	for my $name (qw(lastTrack)) {

		$class->$name({});
	}

	$trackAttrs = Slim::Schema::Track->attributes;
	
	if ( !main::SLIM_SERVICE ) {
		$trackPersistentAttrs = Slim::Schema::TrackPersistent->attributes;
	}

	# Use our debug and stats class to get logging and perfmon for db queries
	$class->storage->debugobj('Slim::Schema::Debug');

	$class->updateDebug;

	$class->_buildValidHierarchies;

	$class->schemaUpdated($update);
	
	if ( main::SLIM_SERVICE ) {
		# Create new empty database every time we startup
		require File::Slurp;
		require FindBin;
		
		my $text = File::Slurp::read_file( "$FindBin::Bin/SQL/slimservice/slimservice-sqlite.sql" );
		
		$text =~ s/\s*--.*$//g;
		for my $sql ( split (/;/, $text) ) {
			next unless $sql =~ /\w/;
			$dbh->do($sql);
		}
	}

	# Migrate the old Mov content type to mp4 and aac - done here as at pref migration time, the database is not loaded
	if ( !main::SLIM_SERVICE && !main::SCANNER &&
		 !$prefs->get('migratedMovCT') && Slim::Schema->count('Track', { 'me.content_type' => 'mov' }) ) {

		$log->warn("Migrating 'mov' tracks to new database format");

		Slim::Schema->rs('Track')->search({ 'me.content_type' => 'mov', 'me.remote' => 1 })->delete_all;

		my $rs = Slim::Schema->rs('Track')->search({ 'me.content_type' => 'mov' });

		while (my $track = $rs->next) {

			if ($track->url =~ /\.(mp4|m4a|m4b)$/) {
				$track->content_type('mp4');
				$track->update;
			}

			if ($track->url =~ /\.aac$/) {
				$track->content_type('aac');
				$track->update;
			}
		}

		$prefs->set('migratedMovCT' => 1);
	}

	$initialized = 1;
}

sub hasLibrary {
	return $initialized;
}

sub _connect {
	my ( $class, $dsn, $sql ) = @_;
	
	$sql ||= [];
	
	my ($driver, $source, $username, $password) = $class->sourceInformation;

	# For custom exceptions
	$class->storage_type('Slim::Schema::Storage');
	
	my $on_connect_do = $sqlHelperClass->on_connect_do();
	
	$class->connection( $dsn || $source, $username, $password, { 
		RaiseError    => 1,
		AutoCommit    => 1,
		PrintError    => 0,
		Taint         => 1,
		on_connect_do => [
			@{$on_connect_do},
			@{$sql},
		]
	} ) || return;
	
	return $class->storage->dbh;
}

=head2 throw_exception( $self, $msg )

Override L<DBIx::Class::Schema>'s throw_exception method to use our own error
reporting via L<Slim::Utils::Misc::msg>.

=cut

sub throw_exception {
	my ($self, $msg) = @_;

	logBacktrace($msg);
}

=head2 updateDebug

Check and update debug status for the storage class.
Debugging is normally disabled, but must be enabled if either logging for database.sql or perfmon is required

=cut

sub updateDebug {
	my $class  = shift;

	return if !$initialized;
	
	my $debug  = (main::INFOLOG && logger('database.sql')->is_info) || main::PERFMON;

	$class->storage->debug($debug);
}

=head2 disconnect()

Disconnect from the database, and ununtialize the class.

=cut

sub disconnect {
	my $class = shift;

	eval { $class->storage->dbh->disconnect };
	
	if ( main::SLIM_SERVICE ) {
		# Delete the database file on shutdown
		my $config = SDI::Util::SNConfig::get_config();
		my $db = ( $config->{database}->{sqlite_path} || '.' ) . "/slimservice.$$.db";
		unlink $db;
	}

	$initialized = 0;
}

=head2 validHierarchies()

Returns a hash ref of valid hierarchies that a user is allowed to traverse.

Eg: genre,contributor,album,track

=cut

sub validHierarchies {
	my $class = shift;

	return \%validHierarchies;
}

=head2 sourceInformation() 

Returns in order: database driver name, DBI DSN string, username, password
from the current settings.

=cut

sub sourceInformation {
	my $class = shift;

	my $source   = $sqlHelperClass->source();
	my $username = $prefs->get('dbusername');
	my $password = $prefs->get('dbpassword');
	
	my ($driver) = ($source =~ /^dbi:(\w+):/);

	return ($driver, $source, $username, $password);
}

=head2 wipeDB() 

Wipes and reinitializes the database schema. Calls the schema_clear.sql script
for the current database driver.

WARNING - All data in the database will be dropped!

=cut

sub wipeDB {
	my $class = shift;
	
	if ( main::SLIM_SERVICE ) {
		return;
	}
	
	my $log = logger('scan.import');

	main::INFOLOG && $log->is_info && $log->info("Start schema_clear");

	my ($driver) = $class->sourceInformation;

	eval { 
		Slim::Utils::SQLHelper->executeSQLFile(
			$driver, $class->storage->dbh, "schema_clear.sql"
		);

		$class->migrateDB;
	};

	if ($@) {
		logError("Failed to clear & migrate schema: [$@]");
	}

	main::INFOLOG && $log->is_info && $log->info("End schema_clear");
}

=head2 optimizeDB()

Calls the schema_optimize.sql script for the current database driver.

=cut

sub optimizeDB {
	my $class = shift;
	
	# Only optimize in the scanner
	return unless main::SCANNER;
	
	my $log = logger('scan.import');

	main::INFOLOG && $log->is_info && $log->info("Start schema_optimize");

	my ($driver) = $class->sourceInformation;

	eval {
		Slim::Utils::SQLHelper->executeSQLFile(
			$driver, $class->storage->dbh, "schema_optimize.sql"
		);
	};

	if ($@) {
		logError("Failed to optimize schema: [$@]");
	}

	main::INFOLOG && $log->is_info && $log->info("End schema_optimize");
}

=head2 migrateDB()

Migrates the current schema to the latest schema version as defined by the
data files handed to L<DBIx::Migration>.

=cut

sub migrateDB {
	my $class = shift;
	
	if ( main::SLIM_SERVICE ) {
		return;
	}

	my $dbh = $class->storage->dbh;
	my ($driver, $source, $username, $password) = $class->sourceInformation;

	# Migrate to the latest schema version - see SQL/$driver/schema_\d+_up.sql
	my $dbix = DBIx::Migration->new({
		dbh   => $dbh,  
		dir   => catdir(Slim::Utils::OSDetect::dirsFor('SQL'), $driver),
		debug => $log->is_debug,
	});
	
	# Hide errors that aren't really errors
	my $cur_handler = $dbh->{HandleError};
	my $new_handler = sub {
		return 1 if $_[0] =~ /no such table/;
		goto $cur_handler;
	};
	
	local $dbh->{HandleError} = $new_handler;

	my $old = $dbix->version || 0;

	if ($dbix->migrate) {

		my $new = $dbix->version || 0;

		if ( main::INFOLOG && $log->is_info ) {
			$log->info(sprintf("Connected to database $source - schema version: [%d]", $new));
		}

		if ($old != $new) {

			if ( $log->is_warn ) {
				$log->warn(sprintf("Migrated database from schema version: %d to version: %d", $old, $new));
			}

			return 1;

		}

	} else {

		# this occurs if a user downgrades Squeezebox Server to a version with an older schema and which does not include
		# the required downgrade sql scripts - attempt to drop and create the database at current schema version

		if ( $log->is_warn ) {
			$log->warn(sprintf("Unable to downgrade database from schema version: %d - Attempting to recreate database", $old));
		}

		eval { $class->storage->dbh->do('DROP TABLE IF EXISTS dbix_migration') };

		if ($dbix->migrate) {

			if ( $log->is_warn ) {
				$log->warn(sprintf("Successfully created database at schema version: %d", $dbix->version));
			}

			return 1;

		}

		logError(sprintf("Unable to create database - **** You may need to manually delete the database ****", $old));

	}

	return 0;
}

=head2 changeCollation ( $collation )

Change the collation for tables where sorting is important.

=cut

sub changeCollation {
	my ( $class, $collation ) = @_;
	
	$sqlHelperClass->changeCollation( $class->storage->dbh, $collation );
}

=head2 rs( $class )

Returns a L<DBIx::Class::ResultSet> for the specified class.

A shortcut for resultset()

=cut 

sub rs {
	my $class   = shift;
	my $rsClass = ucfirst shift;
	
	if ( !exists $RS_CACHE{$rsClass} ) {
		$RS_CACHE{$rsClass} = $class->resultset($rsClass);
	}

	return $RS_CACHE{$rsClass};
}

=head2 search( $class, $cond, $attr )

Returns a L<DBIx::Class::ResultSet> for the specified class.

A shortcut for resultset($class)->search($cond, $attr)

=cut 

sub search {
	my $class   = shift;
	my $rsClass = shift;

	return $class->rs(ucfirst($rsClass))->search(@_);
}

=head2 single( $class, $cond )

Returns a single result from a search on the specified class' L<DBIx::Class::ResultSet>

A shortcut for resultset($class)->single($cond)

=cut 

sub single {
	my $class   = shift;
	my $rsClass = shift;

	return $class->rs(ucfirst($rsClass))->single(@_);
}

=head2 count( $class, $cond, $attr )

Returns the count result from a search on the specified class' L<DBIx::Class::ResultSet>

A shortcut for resultset($class)->count($cond, $attr)

=cut 

sub count {
	my $class   = shift;
	my $rsClass = shift;

	return $class->rs(ucfirst($rsClass))->count(@_);
}

=head2 find( $class, $cond, $attr )

Returns an object result from a search on the specified class'
L<DBIx::Class::ResultSet>. This find is done on the class' primary key.

If the requested class is L<Slim::Schema::Track>, a validity check is dne
before returning.

Overrides L<DBIx::Class::ResultSet::find>

=cut 

sub find {
	my $class   = shift;
	my $rsClass = ucfirst(shift);
	
	# If we only have a single attribute and it is not a reference and it is negative
	# then this indicates a remote track.
	if (@_ == 1 && ! ref $_[0] && $_[0] < 0) {
		return Slim::Schema::RemoteTrack->fetchById($_[0]);
	}
	
	return if !$initialized;

	my $object  = eval { $class->rs($rsClass)->find(@_) };

	if ($@) {

		logBacktrace("Failed: [$@]. Returning undef.");

		return undef;
	}

	# If we're requesting a Track - make sure it's still on disk and valid.
	# Do not do this if we're in the scanner, the artwork scanner calls this
	# but we do not need to stat all the files again
	if ( !main::SCANNER && $rsClass eq 'Track' ) {
		$object = $class->_checkValidity($object)
	}

	return $object;
}

=head2 searchTypes()

Returns commmon searchable types - constant values: contributor, album, track.

=cut

# Return the common searchable types.
sub searchTypes {
	my $class = shift;

	return qw(contributor album genre track);
}

=head2 contentType( $urlOrObj ) 

Fetch the content type for a URL or Track Object.

Try and be smart about the order of operations in order to avoid hitting the
database if we can get a simple file extension match.

=cut

sub contentType {
	my ($self, $urlOrObj) = @_;

	# Bug 15779 - if we have it in the cache then just use it
	# This does not even check that $urlOrObj is actually a URL
	# but there should be no practical chance of a key-space clash if it is not.
	if (defined $contentTypeCache{$urlOrObj}) {
		return $contentTypeCache{$urlOrObj};
	}

	my $defaultType = 'unk';
	my $contentType = $defaultType;

	# See if we were handed a track object already, or just a plain url.
	my ($track, $url, $blessed) = _validTrackOrURL($urlOrObj);

	# We can't get a content type on a undef url
	if (!defined $url) {
		return $defaultType;
	}

	# Try again for a cache hit - return immediately.
	if (defined $contentTypeCache{$url}) {
		return $contentTypeCache{$url};
	}

	# Track will be a blessed object if it's defined.
	# If we have an object - return from that.
	if ($track) {

		$contentType = $track->content_type;

	} else {

		# Otherwise, try and pull the type from the path name and avoid going to the database.
		$contentType = Slim::Music::Info::typeFromPath($url);
	}

	# Nothing from the path, and we don't have a valid track object - fetch one.
	if ((!defined $contentType || $contentType eq $defaultType) && !$track) {

		$track   = $self->objectForUrl($url);

		if (isaTrack($track)) {

			$contentType = $track->content_type;
		}
	}

	# Nothing from the object we already have in the db.
	if ((!defined $contentType || $contentType eq $defaultType) && $blessed) {

		$contentType = Slim::Music::Info::typeFromPath($url);
	} 

	# Only set the cache if we have a valid contentType
	if (defined $contentType && $contentType ne $defaultType) {

		$contentTypeCache{$url} = $contentType;
	}

	return $contentType;
}

=head2 objectForUrl( $args )

The workhorse for getting L<Slim::Schema::Track> or L<Slim::Schema::Playlist>
objects from the database.

Based on arguments, will try and search for the url in the database, or
optionally create it if it does not already exist.

Required $args:

=over 4

=item * 

The URL to look for.

=back

Optional $args:

=over 4

=item * create

Create the object (defaults to L<Slim::Schema::Track>) if it does not exist.

=item * readTags

Read metadata tags from the specified file or url.

=item * commit

Commit to the database (if not in AutoCommit mode).

=item * playlist

Find or create the object as a L<Slim::Schema::Playlist>.

=back

Returns a new L<Slim::Schema::Track> or L<Slim::Schema::Playlist> object on success.

=cut

sub objectForUrl {
	my $self = shift;
	my $args = shift;

	# Handle both old and new calling methods.
	# We silently handle the single arg case to fetch a URL.
	my $url        = $args;
	my $create     = 0;
	my $readTag    = 0;
	my $commit     = 0;
	my $playlist   = 0;
	my $checkMTime = 1;
	my $playlistId;

	if (@_) {

		logBacktrace("Callers - please update to pass named args!");

		($url, $create, $readTag) = ($args, @_);

	} elsif (ref($args) eq 'HASH') {

		$url        = $args->{'url'};
		$create     = $args->{'create'};
		$readTag    = $args->{'readTag'} || $args->{'readTags'};
		$commit     = $args->{'commit'};
		$playlist   = $args->{'playlist'};
		$checkMTime = $args->{'checkMTime'} if defined $args->{'checkMTime'};
		$playlistId = $args->{'playlistId'};
	}

	# Confirm that the URL itself isn't an object (see bug 1811)
	# XXX - exception should go here. Coming soon.
	if (blessed($url) || ref($url)) {

		# returning already blessed url
		return $url;
	}

	if (!$url) {

		logBacktrace("Null track request! Returning undef."); 
		return undef;
	}

	# Create a canonical version, to make sure we only have one copy.
	if ( $url =~ /^(file|http)/i ) {
		$url = URI->new($url)->canonical->as_string;
	}

	# Pull the track object for the DB
	my $track = $self->_retrieveTrack($url, $playlist);
	
	# Bug 14648: Check to see if we have a playlist with remote tracks
	if (!$track && defined $playlistId && Slim::Music::Info::isRemoteURL($url)) {

		if (my $playlistObj = $self->find('Playlist', $playlistId)) {
			# Parse the playlist file to cause the RemoteTrack objects to be created
			Slim::Formats::Playlists->parseList($playlistObj->url);
			
			# try again
			$track = $self->_retrieveTrack($url, $playlist);
		}
	}

	# _retrieveTrack will always return undef or a track object
	elsif ($track && $checkMTime && !$create && !$playlist) {
		$track = $self->_checkValidity($track);
	}

	# _checkValidity will always return undef or a track object
	if (!$track && $create) {

		$track = $self->updateOrCreate({
			'url'      => $url,
			'readTags' => $readTag,
			'commit'   => $commit,
			'playlist' => $playlist,
		});
	}

	return $track;
}

=head2 newTrack( $args )

Create a new track with the given attributes.

Required $args:

=over 4

=item * url

The URL to create in the database.

=back

Optional $args:

=over 4

=item * attributes 

A hash ref with data to populate the object.

=item * id

An explicit record id.

=item * readTags

Read metadata tags from the specified file or url.

=item * commit

Commit to the database (if not in AutoCommit mode).

=item * playlist

Find or create the object as a L<Slim::Schema::Playlist>.

=back

Returns a new L<Slim::Schema::Track> or L<Slim::Schema::Playlist> object on success.

=cut

sub newTrack {
	my $self = shift;
	my $args = shift;
	
	my $isDebug = main::DEBUGLOG && $log->is_debug;
	my $isInfo  = main::INFOLOG && $log->is_info;

	my $url           = $args->{'url'};
	my $attributeHash = $args->{'attributes'} || {};
	my $id            = $args->{'id'} || 0;
	my $playlist      = $args->{'playlist'} || 0;
	my $source        = $playlist ? 'Playlist' : 'Track';

	my $deferredAttributes = {};

	if (!$url) {

		logBacktrace("Null track request! Returning undef");

		return undef;
	}

	main::INFOLOG && $isInfo && $log->info("\nNew $source: [$url]");

	# Default the tag reading behaviour if not explicitly set
	if (!defined $args->{'readTags'}) {
		$args->{'readTags'} = 'default';
	}

	# Read the tag, and start populating the database.
	if ($args->{'readTags'}) {

		main::INFOLOG && $isInfo && $log->info("readTags is ". $args->{'readTags'});

		$attributeHash = { %{Slim::Formats->readTags($url)}, %$attributeHash  };
		
		# Abort early if readTags returned nothing, meaning the file is probably bad/missing
		if ( !scalar keys %{$attributeHash} ) {
			$LAST_ERROR = 'Unable to read tags from file';
			return;
		}
	}

	# Abort early and don't add the track if it's DRM'd
	if ($attributeHash->{'DRM'}) {

		$log->warn("$source has DRM -- skipping it!");
		
		$LAST_ERROR = 'Track is DRM-protected';
		
		return;
	}

	($attributeHash, $deferredAttributes) = $self->_preCheckAttributes({
		'url'        => $url,
		'attributes' => $attributeHash,
		'create'     => 1,
	});

	# Playlists don't have years.
	if ($source eq 'Playlist') {
		delete $attributeHash->{'YEAR'};
	}

	# Creating the track only wants lower case values from valid columns.
	my $columnValueHash = {};
	my $persistentColumnValueHash = {};

	# Walk our list of valid attributes, and turn them into something ->create() can use.
	main::DEBUGLOG && $isDebug && $log->debug("Creating $source with columns:");

	while (my ($key, $val) = each %$attributeHash) {

		$key = lc($key);

		if (defined $val && exists $trackAttrs->{$key}) {
			
			# Bug 7731, filter out duplicate keys that end up as array refs
			if ( ref $val eq 'ARRAY' ) {
				$val = $val->[0];
			}
			
			main::DEBUGLOG && $isDebug && $log->debug("  $key : $val");

			$columnValueHash->{$key} = $val;
		}

		# Metadata is only included if it contains a non zero value
		if ( $val && exists $trackPersistentAttrs->{$key} ) {
			# Bug 7731, filter out duplicate keys that end up as array refs
			if ( ref $val eq 'ARRAY' ) {
				$val = $val->[0];
			}
			
			main::DEBUGLOG && $isDebug && $log->debug("  (persistent) $key : $val");

			$persistentColumnValueHash->{$key} = $val;
		}
	}

	# Tag and rename set URL to the Amazon image path. Smack that.
	# We don't use it anyways.
	$columnValueHash->{'url'} = $url;
	
	# Use an explicit record id if it was passed as an argument.
	if ($id) {
		$columnValueHash->{'id'} = $id;
	}

	# Create the track - or bail. ->throw_exception will emit a backtrace.
	# Using native DBI here to improve performance during scanning
	my $dbh = Slim::Schema->storage->dbh;
	
	my @cols      = keys %{$columnValueHash};
	my $colstring = join( ',', @cols );
	my $ph        = join( ',', map { '?' } @cols );
	
	my $sth = $dbh->prepare_cached("INSERT INTO tracks ($colstring) VALUES ($ph)");
	$sth->execute( map { $columnValueHash->{$_} } @cols );
	
	$id = $dbh->last_insert_id(undef, undef, undef, undef);
	
	# XXX: this is pretty slow
	my $track = Slim::Schema->rs($source)->find($id);

	if ($@ || !blessed($track)) {

		logError("Failed creating $source for $url : $@");
		return;
	}

	if ( main::INFOLOG && $isInfo && $track->title ) {
		 $log->info(sprintf("Created track '%s' (id: [%d])", $track->title, $track->id));
	}

	if ( !main::SLIM_SERVICE && $track->audio ) {
		# Pull the track persistent object for the DB
		my $trackPersistent = $track->retrievePersistent();

		# We only want to store real musicbrainz_id's (conversion programs sometimes generate invalid musicbrainz_id's during conversion)
		if ( exists $persistentColumnValueHash->{musicbrainz_id} && length( $persistentColumnValueHash->{musicbrainz_id} ) != 36 ) {
			delete $persistentColumnValueHash->{musicbrainz_id};
		}

		# retrievePersistent will always return undef or a track metadata object
		if ( !blessed $trackPersistent ) {
			$persistentColumnValueHash->{added} = $track->timestamp;
			$persistentColumnValueHash->{url}   = $track->url;

			# Create the track metadata object- or bail. ->throw_exception will emit a backtrace.
			# XXX native DBI
			$trackPersistent = Slim::Schema->rs('TrackPersistent')->create($persistentColumnValueHash);
	
			if ( $@ || !blessed $trackPersistent ) {
		
				logError("Failed to create TrackPersistent for $url : $@");
				return;
			}
		}
		else {
			while ( my ($key, $val) = each %{$persistentColumnValueHash} ) {

				main::INFOLOG && $log->is_info && $log->info("Updating persistent $url : $key to $val");
				$trackPersistent->set_column( $key => $val );
			}
			
			$trackPersistent->set_column( url => $track->url );
			
			$trackPersistent->update;
		}
	}

	# Now that we've created the track, and possibly an album object -
	# update genres, etc - that we need the track ID for.
	if (!$playlist) {

		$self->_postCheckAttributes({
			'track'      => $track,
			'attributes' => $deferredAttributes,
			'create'     => 1,
		});

		if ($columnValueHash->{'audio'}) {

			$self->lastTrackURL($url);
			$self->lastTrack->{dirname($url)} = $track;
		}
	}

	$self->forceCommit if $args->{'commit'};

	return $track;
}

=head2 updateOrCreate( $args )

Update the attributes of a track or create one if one doesn't already exist.

Required $args:

=over 4

=item * url

The URL to find or create in the database.

=back

Optional $args:

=over 4

=item * attributes

A hash ref with data to populate the object.

=item * readTags

Read metadata tags from the specified file or url.

=item * commit

Commit to the database (if not in AutoCommit mode).

=item * playlist

Find or create the object as a L<Slim::Schema::Playlist>.

=item * checkMTime

Check to see if the track has changed, if not - don't update.

=back

Returns a new L<Slim::Schema::Track> or L<Slim::Schema::Playlist> object on success.

=cut

sub updateOrCreate {
	my $self = shift;
	my $args = shift;

	#
	my $urlOrObj      = $args->{'url'};
	my $attributeHash = $args->{'attributes'} || {};
	my $commit        = $args->{'commit'};
	my $readTags      = $args->{'readTags'} || 0;
	my $checkMTime    = $args->{'checkMTime'};
	my $playlist      = $args->{'playlist'};
	my $isNew         = $args->{'new'} || 0; # save a query if caller knows the track is new

	# XXX - exception should go here. Coming soon.
	my ($track, $url, $blessed) = _validTrackOrURL($urlOrObj);

	if (!defined($url) || ref($url)) {

		logBacktrace("No URL specified! Returning undef.");
		logError(Data::Dump::dump($attributeHash)) if main::DEBUGLOG && !$::quiet;

		return undef;
	}

	# Short-circuit for remote tracks
	if (Slim::Music::Info::isRemoteURL($url)) {
		my $class = $playlist ? 'Slim::Schema::RemotePlaylist' : 'Slim::Schema::RemoteTrack';
		return $class->updateOrCreate($track ? $track : $url, $attributeHash, \%tagMapping);
	}

	# Track will be defined or not based on the assignment above.
	if ( !defined $track && !$isNew ) {
		$track = $self->_retrieveTrack($url, $playlist);
	}
	
	# XXX - exception should go here. Coming soon.
	# _retrieveTrack will always return undef or a track object
	if ($track) {

		# Check the timestamp & size to make sure they've not changed.
		if ($checkMTime && Slim::Music::Info::isFileURL($url) && !$self->_hasChanged($track, $url)) {

			main::INFOLOG && $log->is_info && $log->info("Track is still valid! Skipping update! $url");

			return $track;
		}

		# Pull the track metadata object for the DB if available
		my $trackPersistent;
		if ( !main::SLIM_SERVICE ) {
			$trackPersistent = $track->retrievePersistent();
		}
	
		# Bug: 2335 - readTags is set in Slim::Formats::Playlists::CUE - when
		# we create/update a cue sheet to have a CT of 'cur'
		if (defined $attributeHash->{'CONTENT_TYPE'} && $attributeHash->{'CONTENT_TYPE'} eq 'cur') {
			$readTags = 0;
		}

		main::INFOLOG && $log->is_info && $log->info("Merging entry for $url readTags is: [$readTags]");

		# Force a re-read if requested.
		# But not for remote / non-audio files.
		if ($readTags && $track->get('audio')) {

			$attributeHash = { %{Slim::Formats->readTags($url)}, %$attributeHash  };
		}

		my $deferredAttributes;
		($attributeHash, $deferredAttributes) = $self->_preCheckAttributes({
			'url'        => $url,
			'attributes' => $attributeHash,
		});

		while (my ($key, $val) = each %$attributeHash) {

			$key = lc($key);

			if (defined $val && $val ne '' && exists $trackAttrs->{$key}) {

				main::INFOLOG && $log->is_info && $log->info("Updating $url : $key to $val");

				$track->set_column($key, $val);
			}

			# Metadata is only included if it contains a non zero value
			if ( $val && blessed($trackPersistent) && exists $trackPersistentAttrs->{$key} ) {

				main::INFOLOG && $log->is_info && $log->info("Updating persistent $url : $key to $val");

				$trackPersistent->set_column( $key => $val );
			}
		}

		# _postCheckAttributes does an update
		if (!$playlist) {

			$self->_postCheckAttributes({
				'track'      => $track,
				'attributes' => $deferredAttributes,
			});
		}

		$self->forceCommit if $commit;

	} else {

		$track = $self->newTrack({
			'url'        => $url,
			'attributes' => $attributeHash,
			'readTags'   => $readTags,
			'commit'     => $commit,
			'playlist'   => $playlist,
		});
		
		if ( $track ) {
			$attributeHash->{'CONTENT_TYPE'} = $track->content_type;
		}
	}

	if ($track && $attributeHash->{'CONTENT_TYPE'}) {
		$contentTypeCache{$url} = $attributeHash->{'CONTENT_TYPE'};
	}

	return $track;
}

=head2 cleanupStaleTrackEntries()

Post-scan garbage collection routine. Checks for files that are in the
database, but are not on disk. After the track check, runs
L<Slim::Schema::DBI->removeStaleDBEntries> for each of Album, Contributor &
Genre looking for and removing orphan entries in the database.

=cut

sub cleanupStaleTrackEntries {
	my $self = shift;
	
	my $log = logger('scan.import');

	# Cleanup any stale entries in the database.
	# 
	# First walk the list of tracks, checking to see if the
	# file/directory/shortcut still exists on disk. If it doesn't, delete
	# it. This will cascade ::Track's has_many relationships, including
	# contributor_track, etc.
	#
	# After that, walk the Album, Contributor & Genre tables, to see if
	# each item has valid tracks still. If it doesn't, remove the object.

	main::INFOLOG && $log->is_info && $log->info("Starting db garbage collection..");

	# BUG 4355 only search for local audio files, as we cannot check
	# validity of remote files
	my $iterator = $self->search('Track', { 'audio' => 1, 'remote' => 0 });
	my $count    = $iterator->count;

	my $progress = Slim::Utils::Progress->new({
		'type' => 'importer', 'name' => 'cleanup1', 'total' => $count, 'bar' => 1
	});

	# fetch one at a time to keep memory usage in check.
	while (my $track = $iterator->next) {

		# _hasChanged will delete tracks
		if ($self->_hasChanged($track, $track->get('url'))) {

			$track = undef;
		}

		$progress->update;
	}

	$progress->final;

	main::INFOLOG && $log->is_info && $log->info("Finished with stale track cleanup.");

	# Walk the Album, Contributor and Genre tables to see if we have any dangling
	# entries, pointing to non-existant tracks.

	$progress = Slim::Utils::Progress->new({ 'type' => 'importer', 'name' => 'cleanup2' });

	Slim::Schema::Contributor->removeStaleDBEntries('contributorTracks');
	Slim::Schema::Album->removeStaleDBEntries('tracks');
	Slim::Schema::Genre->removeStaleDBEntries('genreTracks');

	$progress->final;

	# We're done.
	$self->forceCommit;

	Slim::Music::Import->endImporter('cleanupStaleEntries');

	return 1;
}

=head2 variousArtistsObject()

Returns a singleton object representing the artist 'Various Artists'

=cut

sub variousArtistsObject {
	my $self = shift;

	my $vaString = Slim::Music::Info::variousArtistString();

	# Fetch a VA object and/or update it's name if the user has changed it.
	# XXX - exception should go here. Coming soon.
	if (!blessed($vaObj) || !$vaObj->can('name')) {

		$vaObj  = $self->rs('Contributor')->update_or_create({
			'name'       => $vaString,
			'namesearch' => Slim::Utils::Text::ignoreCaseArticles($vaString),
			'namesort'   => Slim::Utils::Text::ignoreCaseArticles($vaString),
		}, { 'key' => 'namesearch' });

		main::DEBUGLOG && $log->is_debug && $log->debug(sprintf("-- Created VARIOUS ARTIST (id: [%d])", $vaObj->id));
	}

	if ($vaObj && $vaObj->name ne $vaString) {

		$vaObj->name($vaString);
		$vaObj->namesort( Slim::Utils::Text::ignoreCaseArticles($vaString) );
		$vaObj->namesearch( Slim::Utils::Text::ignoreCaseArticles($vaString) );
		$vaObj->update;
	}

	return $vaObj;
}

=head2 variousArtistsAlbumCount( $find )

Wrapper for the common case of checking the level below the current one
(always Albums), to see if any Various Artists albums exist.

=cut

sub variousArtistsAlbumCount {
	my $class = shift;

	# Bug 3983, 4059: clone the provided hash reference so we don't mung further
	# processing outside this function.
	my $find  = Storable::dclone(shift);

	my %attr = ( 'group_by' => 'me.id' );
	my @join = ();

	# We always want to search for compilation
	$find->{'me.compilation'} = 1;

	if (exists $find->{'genre.id'}) {

		$find->{'genreTracks.genre'} = delete $find->{'genre.id'};
		push @join, { 'tracks' => 'genreTracks' };

	} elsif (exists $find->{'genre.name'}) {

		push @join, { 'tracks' => { 'genreTracks' => 'genre' } };
	}

	$attr{'join'} = \@join;

	return $class->count('Album', $find, \%attr);
}

=head2 trackCount()

Returns the number of local audio tracks in the database.

=cut

sub trackCount {
	my $self = shift;

	return $self->count('Track', { 'me.audio' => 1 });
}

=head2 totalTime()

Returns the total (cumulative) time in seconds of all audio tracks in the database.

=cut

sub totalTime {
	my $self = shift;

	return 0 unless $self->trackCount();

	# Pull out the total time dynamically.
	# What a breath of fresh air. :)
	return $self->search('Track', { 'audio' => 1 }, {

		'select' => [ \'SUM(secs)' ],
		'as'     => [ 'sum' ],

	})->single->get_column('sum');
}

=head2 mergeVariousArtistsAlbums()

Run a post-process on the albums and contributor_tracks tables, in order to
identify albums which are compilations / various artist albums - by virtue of
having more than one artist.

=cut

sub mergeVariousArtistsAlbums {
	my $self = shift;
	
	my $isDebug   = main::DEBUGLOG && $log->is_debug;
	my $importlog = main::INFOLOG ? logger('scan.import') : undef;

	my $vaObjId = $self->variousArtistsObject->id;
	my $role    = Slim::Schema::Contributor->typeToRole('ARTIST');

	my $cursor  = $self->search('Album', {

		'me.compilation' => undef,
		
		# BUG4193: allow processing 'no album' so we resolve the multiple artists
		#'me.title'       => { '!=' => string('NO_ALBUM') },

	})->distinct;

	my $progress = undef;
	my $count    = $cursor->count;

	if ($count) {
		$progress = Slim::Utils::Progress->new({
			'type' => 'importer', 'name' => 'mergeva', 'total' => $count, 'bar' => 1
		});
	}

	# fetch one at a time to keep memory usage in check.
	while (my $albumObj = $cursor->next) {
		
		$self->mergeSingleVAAlbum( $albumObj, $vaObjId, $role );

		$progress->update($albumObj->name);
	}

	$progress->final($count) if $count;

	Slim::Music::Import->endImporter('mergeVariousAlbums');
}

=head2 mergeSingleVAAlbum($album)

Merge a single VA album

=cut

sub mergeSingleVAAlbum {
	my ( $self, $albumObj, $vaObjId, $role ) = @_;
	
	my $isDebug   = main::DEBUGLOG && $log->is_debug;
	my $importlog = main::INFOLOG ? logger('scan.import') : undef;
	
	my %trackArtists      = ();
	my $markAsCompilation = 0;
	
	if ( !$vaObjId ) {
		$vaObjId = $self->variousArtistsObject->id;
	}
	
	if ( !$role ) {
		$role = Slim::Schema::Contributor->typeToRole('ARTIST');
	}

	main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- VA postcheck for album '%s' (id: [%d])", $albumObj->name, $albumObj->id));

	# Bug 2066: If the user has an explict Album Artist set -
	# don't try to mark it as a compilation. So only fetch ARTIST roles.
	my $tracks = $albumObj->tracks({ 'contributorTracks.role' => $role }, { 'prefetch' => 'contributorTracks' });

	while (my $track = $tracks->next) {

		# Don't inflate the contributor object.
		my @contributors = sort map {
			$_->get_column('contributor')
		} $track->search_related('contributorTracks')->all;

		# Create a composite of the artists for the track to compare below.
		$trackArtists{ join(':', @contributors) } = 1;
		
		main::DEBUGLOG && $isDebug && $log->debug(sprintf("--- Album has composite artist '%s'", join(':', @contributors)));
	}

	# Bug 2418 was fixed here -- but we don't do it anymore
	# (hardcoded artist of 'Various Artists' making the album a compilation)
	if (scalar values %trackArtists > 1) {

		$markAsCompilation = 1;

	} else {

		my ($artistId) = keys %trackArtists;

		# Use eq here instead of ==, because the artistId
		# might be a composite from above, if all of the
		# tracks in an album have the same (multiple) artists.
		if ($artistId && $artistId eq $vaObjId) {

			$markAsCompilation = 1;
		}
	}

	if ($markAsCompilation) {

		main::INFOLOG && $importlog->is_info && $importlog->info(sprintf("Import: Marking album: [%s] as a compilation.", $albumObj->title));

		main::DEBUGLOG && $isDebug && $log->debug("--- Album is a VA");

		$albumObj->compilation(1);
		$albumObj->contributor($vaObjId);
		$albumObj->update;
	}
}

=head2 wipeCaches()

Clears the lastTrack caches, and forces a database commit.

=cut

sub wipeCaches {
	my $self = shift;

	$self->forceCommit;

	%contentTypeCache = ();
	
	%TOTAL_CACHE = ();

	# clear the references to these singletons
	$vaObj          = undef;
	$_unknownArtist = '';
	$_unknownGenre  = '';
	$_unknownAlbum  = '';

	$self->lastTrackURL('');
	$self->lastTrack({});
	
	Slim::Schema::Contributor->wipeCaches();
	
	# Wipe cached data used for Jive, i.e. albums query data
	if (!main::SCANNER) {	
		Slim::Control::Queries::wipeCaches();
	}

	main::INFOLOG && logger('scan.import')->info("Wiped all in-memory caches.");
}

=head2 wipeAllData()

Wipe all data in the database. Encapsulates L<wipeDB> and L<wipeCaches>

=cut

sub wipeAllData {
	my $self = shift;

	$self->wipeCaches;
	$self->wipeDB;

	main::INFOLOG && logger('scan.import')->info("Wiped the database.");
}

=head2 forceCommit()

Flush any pending database transactions to disk when not in AutoCommit mode.

=cut

sub forceCommit {
	my $self = shift;

	if (!$initialized) {

		logWarning("Trying to commit transactions before DB is initialized!");
		return;
	}

	$self->lastTrackURL('');
	$self->lastTrack({});

	if (!$self->storage->dbh->{'AutoCommit'}) {

		main::INFOLOG && $log->is_info && $log->info("Syncing to the database.");

		eval { $self->storage->dbh->commit };

		if ($@) {
			logWarning("Couldn't commit transactions to DB: [$@]");
			return;
		}
	}
	else {
		main::DEBUGLOG && $log->is_debug && $log->debug("forceCommit ignored, database is in AutoCommit mode");
	}
}

=head2 artistOnlyRoles( @add );

Return an array ref of valid roles as defined by
L<Slim::Schema::Contributor::contributorRoles>, based on the user's current
prefernces for including Composers, Conductors & Bands when browsing their
audio collection via 'Contributors'.

If a caller wishes to force an addition to the list of roles, pass in the
additional roles.

=cut

sub artistOnlyRoles {
	my $self  = shift;
	my @add   = @_;

	my %roles = (
		'ARTIST'      => 1,
		'ALBUMARTIST' => 1,
	);

	# If the user has requested explict roles to be added, do so.
	for my $role (@add) {

		if ($role) {
			$roles{$role} = 1;
		}
	}

	# And if the user has asked for ALL, give them it.
	if ($roles{'ALL'}) {
		return undef;
	}

	# Loop through each pref to see if the user wants to show that contributor role.
	for my $role (Slim::Schema::Contributor->contributorRoles) {

		if ($prefs->get(sprintf('%sInArtists', lc($role)))) {

			$roles{$role} = 1;
		}
	}

	# If we're using all roles, don't bother with the constraint.
	if (scalar keys %roles != Slim::Schema::Contributor->totalContributorRoles) {

		return [ sort map { Slim::Schema::Contributor->typeToRole($_) } keys %roles ];
	}

	return undef;
}

sub registerRatingImplementation {
	my ( $class, $source, $impl ) = @_;

	if ( ref $impl eq 'CODE' ) {
		$ratingImplementations{$source} = $impl;
	}
}

sub ratingImplementations {
	return [ sort keys %ratingImplementations ];
}

sub rating {
	my ( $class, $track, $rating ) = @_;

	my $impl = $prefs->get('ratingImplementation');
	
	if ( !$impl || !exists $ratingImplementations{$impl} ) {
		$impl = 'LOCAL_RATING_STORAGE';
	}

	return $ratingImplementations{$impl}->( $track, $rating );
}

#
# Private methods:
#

sub _defaultRatingImplementation {
	my ( $track, $rating ) = @_;

	if ( defined $rating ) {
		$track->rating($rating);
		$track->update;
		Slim::Schema->forceCommit;
	}
	
	return $track->rating;
}

sub _retrieveTrack {
	my ($self, $url, $playlist) = @_;

	return undef if !$url;
	return undef if ref($url);

	my $track;
	
	if (Slim::Music::Info::isRemoteURL($url)) {
		return Slim::Schema::RemoteTrack->fetch($url, $playlist);
	}

	# Keep the last track per dirname.
	my $dirname = dirname($url);
	my $source  = $playlist ? 'Playlist' : 'Track';

	if (!$playlist && defined $self->lastTrackURL && $url eq $self->lastTrackURL) {

		$track = $self->lastTrack->{$dirname};

	} else {

		$track = $self->rs($source)->single({ 'url' => $url });
	}

	# XXX - exception should go here. Coming soon.
	if (blessed($track)) {

		if (!$playlist || $track->audio) {
			$self->lastTrackURL($url);
			$self->lastTrack->{$dirname} = $track;
			
			# Set the contentTypeCache entry here is case 
			# it was guessed earlier without knowing the real type
			$contentTypeCache{$url} = $track->content_type;
		}

		return $track;
	}

	return undef;
}

sub _retrieveTrackMetadata {
	my ($self, $url, $musicbrainz_id) = @_;

	return undef if !$url;
	return undef if ref($url);

	my $trackMetadata;

	$trackMetadata = $self->rs('TrackMetadata')->single({ 'url' => $url });

	if (blessed($trackMetadata)) {
		return $trackMetadata;
	}elsif($musicbrainz_id) {
		$trackMetadata = $self->rs('TrackMetadata')->single({ 'musicbrainz_id' => $musicbrainz_id });
		return $trackMetadata if blessed($trackMetadata);
	}

	return undef;
}

sub _checkValidity {
	my $self  = shift;
	my $track = shift;

	# XXX - exception should go here. Coming soon.
	return undef unless blessed($track);
	return undef unless $track->can('get');
	
	# Remote tracks are always assumed to be valid
	# Maybe we will add a timeout mechanism later
	return $track if $track->isRemoteURL();
	
	my $isDebug = main::DEBUGLOG && $log->is_debug;

	my $url = $track->get('url');

	main::DEBUGLOG && $isDebug && $log->debug("Checking to see if $url has changed.");

	# Don't check for things that aren't audio
	if ($track->get('audio') && $self->_hasChanged($track, $url)) {

		main::DEBUGLOG && $isDebug && $log->debug("Re-reading tags from $url as it has changed.");

		my $oldid = $track->id;
		
		# Do a cascading delete for has_many relationships - this will
		# clear out Contributors, Genres, etc.
		$track->delete;
		
		# Add the track back into database with the same id as the record deleted.
		$track = $self->newTrack({
			'id'       => $oldid,
			'url'      => $url,
			'readTags' => 1,
			'commit'   => 1,
		});
		
	}
	
	# Track may have been deleted by _hasChanged
	return undef unless $track->in_storage;

	return undef unless blessed($track);
	return undef unless $track->can('url');

	return $track;
}

sub _hasChanged {
	my ($self, $track, $url) = @_;
	
	my $isDebug = main::DEBUGLOG && $log->is_debug;

	# We return 0 if the file hasn't changed
	#    return 1 if the file has been changed.

	# Don't check anchors - only the top level file.
	return 0 if Slim::Utils::Misc::anchorFromURL($url);

	my $filepath = Slim::Utils::Misc::pathFromFileURL($url);

	main::DEBUGLOG && $isDebug && $log->debug("Checking for [$filepath] - size & timestamp.");

	# Return if it's a directory - they expire themselves 
	# Todo - move directory expire code here?
	return 0 if -d $filepath;
	return 0 if $filepath =~ /\.lnk$/i;

	# See if the file exists
	#
	# Reuse _, as we only need to stat() once.
	if (-e _) {

		my $filesize  = $track->get('filesize');
		my $timestamp = $track->get('timestamp');

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
		
		# Bug 4402, if the entire volume/drive this file is on is unavailable,
		# it's likely removable storage and shouldn't be deleted
		my $offline;
			
		if ( main::ISWINDOWS ) {
			# win32, check the drive letter
			my $parent = Path::Class::File->new($filepath)->dir;
			if ( my $vol = $parent->volume ) {
				if ( !-d $vol ) {
					$offline = 1;
				}
			}
		}
		elsif ( main::ISMAC ) {
			# Mac, check if path is in /Volumes
			if ( $filepath =~ m{^/Volumes/([^/]+)} ) {
				if ( !-d "/Volumes/$1" ) {
					$offline = 1;
				}
			}
		}
		else {
			# XXX: Linux/Unix, not sure how to tell if a given path
			# is from an unmounted filesystem
		}
		
		if ( $offline ) {
			main::DEBUGLOG && $isDebug && $log->debug( "Drive/Volume containing [$filepath] seems to be offline, skipping" );
			return 0;
		}

		main::DEBUGLOG && $isDebug && $log->debug("Removing [$filepath] from the db as it no longer exists.");

		# Be sure to clear the track out of the cache as well.
		if ($self->lastTrackURL && $url eq $self->lastTrackURL) {
			$self->lastTrackURL('');
		}

		my $dirname = dirname($url);

		if (defined $self->lastTrack->{$dirname} && $self->lastTrack->{$dirname}->url eq $url) {
			delete $self->lastTrack->{$dirname};
		}

		$track->delete;
		$track = undef;

		$self->forceCommit;

		return 0;
	}
}

sub _preCheckAttributes {
	my $self = shift;
	my $args = shift;

	my $url    = $args->{'url'};
	my $create = $args->{'create'} || 0;

	my $deferredAttributes = {};

	# Copy the incoming hash, so we don't modify it
	my $attributes = { %{ $args->{'attributes'} } };

	# Normalize attribute names
	while (my ($key, $val) = each %$attributes) {

		if (exists $tagMapping{lc $key}) {

			$attributes->{ uc($tagMapping{lc $key}) } = delete $attributes->{$key};
		}
	}
	
	# Bug 9359, don't allow tags named 'ID'
	if ( exists $attributes->{'ID'} ) {
		delete $attributes->{'ID'};
	}

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

	# Some formats stick a DISC tag such as 1/2 or 1-2 into the field.
	if ($attributes->{'DISC'} && $attributes->{'DISC'} =~ m|^(\d+)[-/](\d+)$|) {

		$attributes->{'DISC'}  = $1;

		if (!$attributes->{'DISCC'}) {

			$attributes->{'DISCC'} = $2;
		}
	}

	# Don't insert non-numeric or '0' YEAR fields into the database. Bug: 2610
	# Same for DISC - Bug 2821
	for my $tag (qw(YEAR DISC DISCC BPM)) {

		if ( 
		    defined $attributes->{$tag} 
		    &&
		    ( $attributes->{$tag} !~ /^\d+$/ || $attributes->{$tag} == 0 ) 
		) {
			delete $attributes->{$tag};
		}
	}

	# Bug 4823 - check boundaries set by our tinyint schema.
	for my $tag (qw(DISC DISCC)) {

		if (!defined $attributes->{$tag}) {
			next;
		}

		if ($attributes->{$tag} > 254) {

			$attributes->{$tag} = 254;
		}

		if ($attributes->{$tag} < 0) {

			$attributes->{$tag} = 0;
		}
	}

	# Bug 3759 - Set undef years to 0, so they're included in the count.
	# Bug 3643 - rating is specified as a tinyint - users running their
	# own SQL server may have strict mode turned on.
	for my $tag (qw(YEAR RATING)) {

		$attributes->{$tag} ||= 0;
	}

	# Some tag formats - APE? store the type of channels instead of the number of channels.
	if (defined $attributes->{'CHANNELS'}) { 

		if ($attributes->{'CHANNELS'} =~ /stereo/i) {

			$attributes->{'CHANNELS'} = 2;

		} elsif ($attributes->{'CHANNELS'} =~ /mono/i) {

			$attributes->{'CHANNELS'} = 1;
		}
	}

	if (defined $attributes->{'TRACKNUM'}) {
		$attributes->{'TRACKNUM'} = Slim::Music::Info::cleanTrackNumber($attributes->{'TRACKNUM'});
	}

	# Munge the replaygain values a little
	for my $gainTag (qw(REPLAYGAIN_TRACK_GAIN REPLAYGAIN_TRACK_PEAK)) {

		my $shortTag = $gainTag;
		   $shortTag =~ s/^REPLAYGAIN_TRACK_(\w+)$/REPLAY_$1/;

		if (defined $attributes->{$gainTag}) {
		    
			$attributes->{$shortTag} = delete $attributes->{$gainTag};
			$attributes->{$shortTag} =~ s/\s*dB//gi;
			$attributes->{$shortTag} =~ s/\s//g;  # bug 15965
			$attributes->{$shortTag} =~ s/,/\./g; # bug 6900, change comma to period
			
			# Bug 15483, remove non-numeric gain tags
			if ( $attributes->{$shortTag} !~ /^[\d\-\+\.]+$/ ) {
				my $file = Slim::Utils::Misc::pathFromFileURL($url);
				$log->error("Invalid ReplayGain tag found in $file: $gainTag -> " . $attributes->{$shortTag} );
				
				delete $attributes->{$shortTag};
			}
		}
	}

	# We can take an array too - from vorbis comments, so be sure to handle that.
	my $comments = [];
	my $rawcomments = [];

	if ($attributes->{'COMMENT'} && !ref($attributes->{'COMMENT'})) {

		$rawcomments = [ $attributes->{'COMMENT'} ];

	} elsif (ref($attributes->{'COMMENT'}) eq 'ARRAY') {

		$rawcomments = $attributes->{'COMMENT'};
	}

	# Bug: 2605 - Get URL out of the attributes - some programs, and
	# services such as www.allofmp3.com add it.
	if ($attributes->{'URL'}) {

		push @$rawcomments, delete $attributes->{'URL'};
	}

	# Look for tags we don't want to expose in comments, and splice them out.
	for my $c ( @{$rawcomments} ) {
		next unless defined $c;
		
		# Bug 15630, ignore strings which have the utf8 flag on but are in fact invalid utf8
		next if utf8::is_utf8($c) && !Slim::Utils::Unicode::looks_like_utf8($c);

		#ignore SoundJam and iTunes CDDB comments, iTunSMPB, iTunPGAP
		if ($c =~ /SoundJam_CDDB_/ ||
		    $c =~ /iTunes_CDDB_/ ||
		    $c =~ /^iTun[A-Z]{4}/ ||
		    $c =~ /^\s*[0-9A-Fa-f]{8}(\+|\s)/ ||
		    $c =~ /^\s*[0-9A-Fa-f]{2}\+[0-9A-Fa-f]{32}/) {

			next;
		}
		
		push @$comments, $c;
	}

	$attributes->{'COMMENT'} = $comments;

	# Bug: 4282 - we've seen multiple lyrics tags
	if ($attributes->{'LYRICS'} && ref($attributes->{'LYRICS'}) eq 'ARRAY') {

		$attributes->{'LYRICS'} = join("\n", @{$attributes->{'LYRICS'}});
	}

	if ( !main::SLIM_SERVICE ) {
		# The ARTISTSORT and ALBUMARTISTSORT tags are normalized in Contributor->add()
		# since the tag may need to be split.  See bugs #295 and #4584.
		#
		# Push these back until we have a Track object.
		for my $tag (Slim::Schema::Contributor->contributorRoles, qw(
			COMMENT GENRE ARTISTSORT PIC APIC ALBUM ALBUMSORT DISCC
			COMPILATION REPLAYGAIN_ALBUM_PEAK REPLAYGAIN_ALBUM_GAIN 
			MUSICBRAINZ_ARTIST_ID MUSICBRAINZ_ALBUM_ARTIST_ID MUSICBRAINZ_ALBUM_ID 
			MUSICBRAINZ_ALBUM_TYPE MUSICBRAINZ_ALBUM_STATUS
			ALBUMARTISTSORT
		)) {

			next unless defined $attributes->{$tag};

			$deferredAttributes->{$tag} = delete $attributes->{$tag};
		}
	}
	
	# Flag if embedded artwork was found
	$attributes->{'COVER'} = 1 if $attributes->{'HAS_COVER'};

	# We also need these in _postCheckAttributes, but they should be set during create()
	$deferredAttributes->{'DISC'} = $attributes->{'DISC'};

	# thumb has gone away, since we have GD resizing.
	delete $attributes->{'THUMB'};

	if (main::DEBUGLOG && $log->is_debug) {

		$log->debug("Report for $url:");
		$log->debug("* Attributes *");

		while (my ($tag, $value) = each %{$attributes}) {

			# Artwork dump is unreadable in logs, so replace with a text tag.  Mor thorough artwork
			# debugging is available using artwork setting and this avoids pointless log bloat.
			if ($tag eq 'ARTWORK') {
				$log->debug(".. $tag : [Binary Image Data]") if defined $value;
			} else {
				$log->debug(".. $tag : $value") if defined $value;
			}
		}

		$log->debug("* Deferred Attributes *");

		while (my ($tag, $value) = each %{$deferredAttributes}) {

			# Artwork dump is unreadable in logs, so replace with a text tag.  Mor thorough artwork
			# debugging is available using artwork setting and this avoids pointless log bloat.
			if ($tag eq 'ARTWORK') {
				$log->debug(".. $tag : [Binary Image Data]") if defined $value;
			} else {
				$log->debug(".. $tag : $value") if defined $value;
			}
		}
	}

	return ($attributes, $deferredAttributes);
}

sub _postCheckAttributes {
	my $self = shift;
	my $args = shift;
	
	my $isDebug = main::DEBUGLOG && $log->is_debug;

	my $track      = $args->{'track'};
	my $attributes = $args->{'attributes'};
	my $create     = $args->{'create'} || 0;

	# Don't bother with directories / lnks. This makes sure "No Artist",
	# etc don't show up if you don't have any.
	my %cols = $track->get_columns;

	my ($trackId, $trackUrl, $trackType, $trackAudio, $trackRemote) = 
		(@cols{qw/id url content_type audio remote/});

	if (!defined $trackType || $trackType eq 'dir' || $trackType eq 'lnk') {

		$track->update;

		return undef;
	}

	# Make a local variable for COMPILATION, that is easier to handle
	my $isCompilation = undef;

	if (defined $attributes->{'COMPILATION'}) {

		# Use eq instead of == here, otherwise perl will warn.
		if ($attributes->{'COMPILATION'} =~ /^(?:yes|true)$/i || $attributes->{'COMPILATION'} eq 1) {

			$isCompilation = 1;

			main::DEBUGLOG && $isDebug && $log->debug("-- Track is a compilation");

		} elsif ($attributes->{'COMPILATION'} =~ /^(?:no|false)$/i || $attributes->{'COMPILATION'} eq 0) {

			$isCompilation = 0;

			main::DEBUGLOG && $isDebug && $log->debug("-- Track is NOT a compilation");
		}
	}

	# We don't want to add "No ..." entries for remote URLs, or meta
	# tracks like iTunes playlists.
	my $isLocal = $trackAudio && !$trackRemote ? 1 : 0;

	main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Track is a %s track", $isLocal ? 'local' : 'remote'));

	# Genre addition. If there's no genre for this track, and no 'No Genre' object, create one.
	my $genre = $attributes->{'GENRE'};

	if ($create && $isLocal && !$genre && !blessed($_unknownGenre)) {

		my $genreName = string('NO_GENRE');

		# Bug 3949 - Not sure how this can fail, but it can.
		$_unknownGenre = eval {
			$self->rs('Genre')->update_or_create({
				'name'       => $genreName,
				'namesort'   => Slim::Utils::Text::ignoreCaseArticles($genreName),
				'namesearch' => Slim::Utils::Text::ignoreCaseArticles($genreName),
			}, { 'key' => 'namesearch' });
		};

		if ($@) {
			logError("Couldn't create genre: [$genreName]: [$@]");
		}

		if (blessed($_unknownGenre) && $_unknownGenre->can('name')) {

			Slim::Schema::Genre->add($_unknownGenre->name, $track);

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Created NO GENRE (id: [%d])", $_unknownGenre->id));
			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Track has no genre"));
		}

	} elsif ($create && $isLocal && !$genre && blessed($_unknownGenre)) {

		Slim::Schema::Genre->add($_unknownGenre->name, $track);

		main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Track has no genre"));

	} elsif ($create && $isLocal && $genre) {

		Slim::Schema::Genre->add($genre, $track);

		main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Track has genre '$genre'"));

	} elsif (!$create && $isLocal && $genre && $genre ne $track->genres->single->name) {

		# Bug 1143: The user has updated the genre tag, and is
		# rescanning We need to remove the previous associations.
		$track->genreTracks->delete_all;

		Slim::Schema::Genre->add($genre, $track);

		main::DEBUGLOG && $isDebug && $log->debug("-- Deleted all previous genres for this track");
		main::DEBUGLOG && $isDebug && $log->debug("-- Track has genre '$genre'");
	}

	# Walk through the valid contributor roles, adding them to the database for each track.
	my $contributors     = $self->_mergeAndCreateContributors($track, $attributes, $isCompilation, $isLocal);
	
	# Bug 15553, Primary contributor can only be Album Artist or Artist,
	# so only check for those roles and assign No Artist otherwise
	my $foundContributor = ($contributors->{'ALBUMARTIST'}->[0] || $contributors->{'ARTIST'}->[0]) ? scalar( keys %{$contributors} ) : 0;

	main::DEBUGLOG && $isDebug && $log->debug("-- Track has $foundContributor contributor(s)");

	# Create a singleton for "No Artist"
	if ($create && $isLocal && !$foundContributor) {

		if (!$_unknownArtist) {
			$_unknownArtist = $self->rs('Contributor')->update_or_create({
				'name'       => string('NO_ARTIST'),
				'namesort'   => Slim::Utils::Text::ignoreCaseArticles(string('NO_ARTIST')),
				'namesearch' => Slim::Utils::Text::ignoreCaseArticles(string('NO_ARTIST')),
			}, { 'key' => 'namesearch' });

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Created NO ARTIST (id: [%d])", $_unknownArtist->id));
		}

		Slim::Schema::Contributor->add({
			'artist' => $_unknownArtist->name,
			'role'   => Slim::Schema::Contributor->typeToRole('ARTIST'),
			'track'  => $trackId,
		});

		push @{ $contributors->{'ARTIST'} }, $_unknownArtist;

		main::DEBUGLOG && $isDebug && $log->debug("-- Track has no artist");
	}

	# The "primary" contributor
	my $contributor = ($contributors->{'ALBUMARTIST'}->[0] || $contributors->{'ARTIST'}->[0]);

	if ( main::DEBUGLOG && $isDebug && blessed($contributor) ) {
		$log->debug(sprintf("-- Track primary contributor is '%s' (id: [%d])", $contributor->name, $contributor->id));
	}

	# Now handle Album creation
	my $album    = $attributes->{'ALBUM'};
	my $disc     = $attributes->{'DISC'};
	my $discc    = $attributes->{'DISCC'};
	# Bug 10583 - Also check for MusicBrainz Album Id
	my $albumid  = $attributes->{'MUSICBRAINZ_ALBUM_ID'};
	
	# Bug 4361, Some programs (iTunes) tag things as Disc 1/1, but
	# we want to ignore that or the group discs logic below gets confused
	# Bug 10583 - Revert disc 1/1 change.
	# "Minimal tags" don't help for the "Greatest Hits" problem,
	# either main contributor (ALBUMARTIST) or MB Album Id should be used.
	# In the contrary, "disc 1/1" helps aggregating compilation tracks in different directories.
	# At least, visible presentation is now the same for compilations: disc 1/1 behaves like x/x.
	#if ( $discc && $discc == 1 ) {
	#	$log->debug( '-- Ignoring useless DISCC tag value of 1' );
	#	$disc = $discc = undef;
	#}

	# we may have an album object already..
	# But mark it undef first - bug 3685
	my $albumObj = undef;

	if (!$create && $isLocal) {
		$albumObj = $track->album;

		# Bug: 4140
		# If the track is from a FLAC cue sheet, the original entry
		# will have a 'No Album' album. See if we have a real album name.
		my $noAlbum = string('NO_ALBUM');

		if ($album && $albumObj->title eq $noAlbum && $album ne $noAlbum) {

			$create = 1;
		}
	}

	# Create a singleton for "No Album"
	# Album should probably have an add() method
	if ($create && $isLocal && !$album) {

		my $string = string('NO_ALBUM');

		# let the external scanner make an attempt to find any existing "No Album" in the 
		# database before we assume there are none from previous scans
		$_unknownAlbum = Slim::Schema->rs('album')->searchNames($string)->first;

		if (!$_unknownAlbum) {
			$_unknownAlbum = $self->rs('Album')->update_or_create({
				'title'       => $string,
				'titlesort'   => Slim::Utils::Text::ignoreCaseArticles($string),
				'titlesearch' => Slim::Utils::Text::ignoreCaseArticles($string),
				'compilation' => $isCompilation,
				'year'        => 0,
			}, { 'key' => 'titlesearch' });

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Created NO ALBUM as id: [%d]", $_unknownAlbum->id));
		}

		$track->album($_unknownAlbum->id);
		$albumObj = $_unknownAlbum;

		main::DEBUGLOG && $isDebug && $log->debug("-- Track has no album");

	} elsif ($create && $isLocal && $album) {

		# Used for keeping track of the album name.
		my $basename = dirname($trackUrl);
		
		# Calculate once if we need/want to test for disc
		# Check only if asked to treat discs as separate and
		# if we have a disc, provided we're not in the iTunes situation (disc == discc == 1)
		my $checkDisc = 0;

		# Bug 10583 - Revert disc 1/1 change. Use MB Album Id in addition (unique id per disc, not per set!)
		if (!$prefs->get('groupdiscs') && 
			(($disc && $discc) || ($disc && !$discc) || $albumid)) {

			$checkDisc = 1;
		}

		main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- %shecking for discs", $checkDisc ? 'C' : 'NOT C'));

		# Go through some contortions to see if the album we're in
		# already exists. Because we keep contributors now, but an
		# album can have many contributors, check the disc and
		# album name, to see if we're actually the same.
		#
		# For some reason here we do not apply the same criterias as below:
		# Path, compilation, etc are ignored...
		#
		# Be sure to use get_column() for the title equality check, as
		# get() doesn't run the UTF-8 trigger, and ->title() calls
		# Slim::Schema::Album->title() which has different behavior.

		my ($t, $a); # temp vars to make the conditional sane
		if (
			($t = $self->lastTrack->{$basename}) && 
			$t->get('album') &&
			blessed($a = $t->album) eq 'Slim::Schema::Album' &&
			$a->get_column('title') eq $album &&
			(!$checkDisc || (($disc || '') eq ($a->disc || 0)))

			) {

			$albumObj = $a;

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Same album '%s' (id: [%d]) as previous track", $album, $albumObj->id));

		} else {

			# Don't use year as a search criteria. Compilations in particular
			# may have different dates for each track...
			# If re-added here then it should be checked also above, otherwise
			# the server behaviour changes depending on the track order!
			# Maybe we need a preference?
			my $search = {
				'me.title' => $album,
				#'year'  => $track->year,
			};

			# Add disc to the search criteria if needed
			if ($checkDisc) {

				$search->{'me.disc'} = $disc;

				# Bug 10583 - Also check musicbrainz_id if defined.
				# Can't be used in groupdiscs mode since id is unique per disc, not per set.
				if (defined $albumid) {
					$search->{'me.musicbrainz_id'} = $albumid;
					main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Checking for MusicBrainz Album Id: %s", $albumid));
				}

			} elsif ($discc) {

				# If we're not checking discs - ie: we're in
				# groupdiscs mode, check discc if it exists,
				# in the case where there are multiple albums
				# of the same name by the same artist. bug3254
				$search->{'me.discc'} = $discc;
				
				if ( blessed($contributor) ) {
					# Bug 4361, also match on contributor, so we don't group
					# different multi-disc albums together just because they
					# have the same title
					my $contributor = $contributor->id;
					if ( $isCompilation && !scalar @{ $contributors->{ALBUMARTIST} } ) {
					    $contributor = $self->variousArtistsObject->id;
				    }
			    
					$search->{'me.contributor'} = $contributor;
				}

			} elsif (defined $disc && !defined $discc) {

				# Bug 3920 - In the case where there's two
				# albums of the same name, but one is
				# multidisc _without_ having a discc set.
				$search->{'me.disc'} = { '!=' => undef };
				
				if ( blessed($contributor) ) {
					# Bug 4361, also match on contributor, so we don't group
					# different multi-disc albums together just because they
					# have the same title
					my $contributor = $contributor->id;
					if ( $isCompilation && !scalar @{ $contributors->{ALBUMARTIST} } ) {
					    $contributor = $self->variousArtistsObject->id;
				    }
			    
					$search->{'me.contributor'} = $contributor;
				}
			}

			# Bug 3662 - Only check for undefined/null values if the
			# values are undefined.
			$search->{'me.disc'}  = undef if !defined $disc; 
			$search->{'me.discc'} = undef if !defined $disc && !defined $discc;

			# If we have a compilation bit set - use that instead
			# of trying to match on the artist. Having the
			# compilation bit means that this is 99% of the time a
			# Various Artist album, so a contributor match would fail.
			if (defined $isCompilation) {

				# in the database this is 0 or 1
				$search->{'me.compilation'} = $isCompilation;
			}

			my $attr = {
				'group_by' => 'me.id',
			};

			# Bug 10583 - If we had the MUSICBRAINZ_ALBUM_ID in the tracks table,
			# we could join on it here ...
			# TODO: Join on MUSICBRAINZ_ALBUM_ID if it ever makes it into the tracks table.

			# Join on tracks with the same basename to determine a unique album.
			# Bug 10583 - Only try to aggregate from basename
			# if no MUSICBRAINZ_ALBUM_ID and no DISC and no DISCC available.
			# Bug 11780 - Need to handle groupdiscs mode differently; would leave out
			# basename check if MB Album Id given and thus merge different albums
			# of the same name into one.
			if (
				# In checkDisc mode, try "same folder" only if none of MUSICBRAINZ_ALBUM_ID,
				# DISC and DISCC are known.
				($checkDisc && !defined $albumid && !defined $disc && !defined $discc) ||
				# When not checking discs (i.e., "Group Discs" mode), try "same folder"
				# as a last resort if both DISC and DISCC are unknown.
				(!$checkDisc && !defined $disc && !defined $discc)
				) {

				$search->{'tracks.url'} = { 'like' => "$basename%" };

				$attr->{'join'} = 'tracks';
			}

			# XXX: can return multiple objects
			$albumObj = $self->search('Album', $search, $attr)->single;

			if (main::DEBUGLOG && $isDebug) {

				$log->debug("-- Searching for an album with:");

				while (my ($tag, $value) = each %{$search}) {

					$log->debug(sprintf("--- $tag : %s", Data::Dump::dump($value)));
				}

				if ($albumObj) {

					$log->debug(sprintf("-- Found the album id: [%d]", $albumObj->id));
				}
			}

			# We've found an album above - and we're not looking
			# for a multi-disc or compilation album, check to see
			# if that album already has a track number that
			# corresponds to our current working track and that
			# the other track is not in our current directory. If
			# so, then we need to create a new album. If not, the
			# album object is valid.
			if ($albumObj && $checkDisc && !defined $isCompilation) {

				my $matchTrack = $albumObj->tracks({ 'tracknum' => $track->tracknum })->first;

				if (defined $matchTrack && dirname($matchTrack->url) ne dirname($track->url)) {

					main::INFOLOG && $log->is_info && $log->info(sprintf("-- Track number mismatch with album id: [%d]", $albumObj->id));

					$albumObj = undef;
				}
			}

			# Didn't match anything? It's a new album - create it.
			if (!$albumObj) {

				# XXX native DBI
				$albumObj = $self->rs('Album')->create({ 'title' => $album });

				main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Created album '%s' (id: [%d])", $album, $albumObj->id));
			}
		}
	}

	my $blessedAlbum = blessed($albumObj);

	if ($blessedAlbum && !$self->_albumIsUnknownAlbum($albumObj)) {

		my $sortable_title = Slim::Utils::Text::ignoreCaseArticles($attributes->{'ALBUMSORT'} || $album);

		my %set = ();

		# Always normalize the sort, as ALBUMSORT could come from a TSOA tag.
		$set{'titlesort'}   = $sortable_title;

		# And our searchable version.
		$set{'titlesearch'} = Slim::Utils::Text::ignoreCaseArticles($album);

		# Bug 2393 - was fixed here (now obsolete due to further code rework)
		$set{'compilation'} = $isCompilation;

		# Bug 3255 - add album contributor which is either VA or the primary artist, used for sort by artist
		if ($isCompilation && !scalar @{$contributors->{'ALBUMARTIST'}}) {

			$set{'contributor'} = $self->variousArtistsObject->id;

		} elsif (blessed($contributor)) {

			$set{'contributor'} = $contributor->id;
		}

		$set{'musicbrainz_id'} = $attributes->{'MUSICBRAINZ_ALBUM_ID'};

		# Handle album gain tags.
		for my $gainTag (qw(REPLAYGAIN_ALBUM_GAIN REPLAYGAIN_ALBUM_PEAK)) {

			my $shortTag = lc($gainTag);
			   $shortTag =~ s/^replaygain_album_(\w+)$/replay_$1/;

			# Only update if the existing value is undefined.
			if (defined $albumObj->$shortTag) {
				next;
			}

			if ($attributes->{$gainTag}) {

				$attributes->{$gainTag} =~ s/\s*dB//gi;
				$attributes->{$gainTag} =~ s/\s//g;  # bug 15965
				$attributes->{$gainTag} =~ s/,/\./g; # bug 6900, change comma to period

				$set{$shortTag} = $attributes->{$gainTag};
				
				# Bug 15483, remove non-numeric gain tags
				if ( $set{$shortTag} !~ /^[\d\-\+\.]+$/ ) {
					my $file = Slim::Utils::Misc::pathFromFileURL($trackUrl);
					$log->error("Invalid ReplayGain tag found in $file: $gainTag -> " . $set{$shortTag} );

					delete $set{$shortTag};
				}

			} else {

				$set{$shortTag} = undef;
			}
		}

		# Make sure we have a good value for DISCC if grouping
		# or if one is supplied
		if ($prefs->get('groupdiscs') || $discc) {

			$discc = max(($disc || 0), ($discc || 0), ($albumObj->discc || 0));

			if ($discc == 0) {
				$discc = undef;
			}
		}

		# Check that these are the correct types. Otherwise MySQL will not accept the values.
		if (defined $disc && $disc =~ /^\d+$/) {
			$set{'disc'} = $disc;
		} else {
			$set{'disc'} = undef;
		}

		if (defined $discc && $discc =~ /^\d+$/) {
			$set{'discc'} = $discc;
		} else {
			$set{'discc'} = undef;
		}

		if (defined $track->year && $track->year =~ /^\d+$/) {
			$set{'year'} = $track->year;
		} else {
			$set{'year'} = undef;
		}
		
		# Bug 7731, filter out duplicate keys that end up as array refs
		while ( my ($tag, $value) = each %set ) {
			if ( ref $value eq 'ARRAY' ) {
				$set{$tag} = $value->[0];
			}
		}

		$albumObj->set_columns(\%set);

		if (main::DEBUGLOG && $isDebug) {

			$log->debug(sprintf("-- Updating album '$album' (id: [%d]) with columns:", $albumObj->id));

			while (my ($tag, $value) = each %set) {

				$log->debug("--- $tag : $value") if defined $value;
			}
		}
	}

	# Always do this, no matter if we don't have an Album title.
	if ($blessedAlbum) {

		# Don't add an album to container tracks - See bug 2337
		if (!Slim::Music::Info::isContainer($track, $trackType)) {

			$track->album($albumObj->id);

			main::INFOLOG && $log->is_info && $log->info(sprintf("-- Track has album '%s' (id: [%d])", $albumObj->name, $albumObj->id));
		}

		# Now create a contributors <-> album mapping
		if (!$create && !$self->_albumIsUnknownAlbum($albumObj) && $album) {

			# Update the album title - the user might have changed it.
			$albumObj->title($album);
		}
		
		# Using native DBI here to improve performance during scanning
		my $dbh = Slim::Schema->storage->dbh;

		while (my ($role, $contributorList) = each %{$contributors}) {

			for my $contributorObj (@{$contributorList}) {

				# Bug 4882 - Don't remove contributor <-> album mappings here as its impossible to remove only stale ones
				# Instead recreate this table post scan in the sql optimise script so we can base it on all tracks in an album

				# The following is retained at present to add mappings for BMF, entries created will be deleted in the optimise phase
				my $sth = $dbh->prepare_cached( qq{
					REPLACE INTO contributor_album
					(role, contributor, album)
					VALUES
					(?, ?, ?)
				} );
				$sth->execute( Slim::Schema::Contributor->typeToRole($role), $contributorObj->id, $albumObj->id );

				main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Contributor '%s' (id: [%d]) linked to album '%s' (id: [%d]) with role: '%s'",
					$contributorObj->name, $contributorObj->id, $albumObj->name, $albumObj->id, $role
				));
			}
		}

		$albumObj->update;
	}

	# Save any changes - such as album.
	$track->update;

	# Years have their own lookup table.
	# Bug: 3911 - don't add years for tracks without albums.
	my $year = $track->year;
	
	# Using native DBI here to improve performance during scanning
	my $dbh = Slim::Schema->storage->dbh;

	if (defined $year && $year =~ /^\d+$/ && 
		$blessedAlbum && $albumObj->title ne string('NO_ALBUM')) {
			
		my $sth = $dbh->prepare_cached('SELECT 1 FROM years WHERE id = ?');
		$sth->execute($year);
		my ($exists) = $sth->fetchrow_array;
		$sth->finish;
		
		if ( !$exists ) {
			$sth = $dbh->prepare_cached( 'INSERT INTO years (id) VALUES (?)' );
			$sth->execute($year);
		}
	}

	if ( !main::SLIM_SERVICE ) {
		# Add comments if we have them:
		my $sth = $dbh->prepare_cached( qq{
			REPLACE INTO comments
			(track, value)
			VALUES
			(?, ?)
		} );
		
		for my $comment (@{$attributes->{'COMMENT'}}) {	
			$sth->execute( $trackId, $comment );

			main::DEBUGLOG && $isDebug && $log->debug("-- Track has comment '$comment'");
		}
	}

	# refcount--
	%{$contributors} = ();
}

sub _albumIsUnknownAlbum {
	my ($self, $albumObj) = @_;

	if ($_unknownAlbum && $albumObj->get_column('title') eq $_unknownAlbum->get_column('title')) {

		return 1;
	}

	return 0;
}

sub _mergeAndCreateContributors {
	my ($self, $track, $attributes, $isCompilation, $isLocal) = @_;

	if (!$isLocal) {
		return;
	}
	
	my $isDebug = main::DEBUGLOG && $log->is_debug;

	# Bug: 2317 & 2638
	#
	# Bring back the TRACKARTIST role.
	#
	# If the user has not explictly set a compilation flag, _and_ the user
	# has explict album artist(s) set, make the artist(s) tags become
	# TRACKARTIST contributors for this track.
	if (!defined $isCompilation) {

		if ($attributes->{'ARTIST'} && $attributes->{'ALBUMARTIST'}) {

			$attributes->{'TRACKARTIST'} = delete $attributes->{'ARTIST'};
			# Bug: 6507 - use any ARTISTSORT tag for this contributor
			$attributes->{'TRACKARTISTSORT'} = delete $attributes->{'ARTISTSORT'};

			main::DEBUGLOG && $isDebug && $log->debug(sprintf("-- Contributor '%s' of role 'ARTIST' transformed to role 'TRACKARTIST'",
				$attributes->{'TRACKARTIST'},
			));
		}
	}

	my %contributors = ();

	for my $tag (Slim::Schema::Contributor->contributorRoles) {

		my $contributor = $attributes->{$tag} || next;

		# Is ARTISTSORT/TSOP always right for non-artist
		# contributors? I think so. ID3 doesn't have
		# "BANDSORT" or similar at any rate.
		push @{ $contributors{$tag} }, Slim::Schema::Contributor->add({
			'artist'   => $contributor, 
			'brainzID' => $attributes->{"MUSICBRAINZ_${tag}_ID"},
			'role'     => Slim::Schema::Contributor->typeToRole($tag),
			'track'    => $track,
			'sortBy'   => $attributes->{$tag.'SORT'},
		});

		main::DEBUGLOG && $isDebug && $log->is_debug && $log->debug(sprintf("-- Track has contributor '$contributor' of role '$tag'"));
	}

	return \%contributors;
}

sub _validTrackOrURL {
	my $urlOrObj = shift;

	my $track   = undef;
	my $url     = undef;
	my $blessed = blessed($urlOrObj);

	if (isaTrack($urlOrObj)) {

		$track = $urlOrObj;
		$url   = $track->url;

	}
	elsif ( $urlOrObj && !$blessed ) {

		if ( $urlOrObj =~ /^(file|http)/i ) {
			$url = URI->new($urlOrObj)->canonical->as_string;
		}
		else {
			$url = $urlOrObj;
		}
	}

	return ($track, $url, $blessed);
}

sub _buildValidHierarchies {
	my $class         = shift;

	my @sources       = $class->sources;
	my @browsable     = ();
	my @paths         = ();
	my @finishedPaths = ();
	my @hierarchies   = ();

	no strict 'refs';

	# pare down sources list to ones with a browse method in their ResultSet class.
	for my $source (@sources) {

		if (eval{ "Slim::Schema::ResultSet::$source"->can('browse') }) {
			push @browsable, $source;
		}
	}

	my $max     = $#browsable;
	my $rsCount = $max + 1;
	my @inEdges = () x $rsCount;

	for my $sourceI (0 .. $max) {

		my $source = $browsable[$sourceI];
		my $hasOut = 0;

		# work out the inbound edges of the graph by looking for descendXXX methods
		for my $nextI (0 .. $max) {

			my $nextLevel = $browsable[$nextI];

			if (eval{ "Slim::Schema::ResultSet::$source"->can("descend$nextLevel") }) {

				$hasOut = 1;
				push @{$inEdges[$nextI]}, $sourceI;
			}
		}

		# Add sink nodes to list of paths to process
		if (!$hasOut) {
			push @paths, [[$sourceI],[(0) x $rsCount]];

			# mark node as used in path
			$paths[-1][1][$sourceI] = 1;
		}
	}
	
	use strict 'refs';

	# Work the paths from the sink nodes to the source nodes
	while (scalar(@paths)) {

		my $currPath   = shift @paths;
		my $topNode    = $currPath->[0][0];
		my @toContinue = ();

		# Find all source nodes which are not currently in path
		for my $inEdge (@{$inEdges[$topNode]}) {

			if ($currPath->[1][$inEdge]) {
				next;
			} else {
				push @toContinue, $inEdge;
			}
		}

		# No more nodes possible on this path, put it on the
		# list of finished paths
		if (!scalar(@toContinue)) {
			push @finishedPaths, $currPath->[0];
			next;
		}

		# clone the path if it splits
		while (scalar(@toContinue) > 1) {

			my $newPath = Storable::dclone($currPath);
			my $newTop  = shift @toContinue;

			# add source node to the beginning of the path
			# and mark it as used
			unshift @{$newPath->[0]}, $newTop;
			$newPath->[1][$newTop] = 1;

			push @paths,$newPath;
		}

		# reuse the original path
		unshift @{$currPath->[0]}, $toContinue[0];
		$currPath->[1][$toContinue[0]] = 1;

		push @paths,$currPath;
	}

	# convert array indexes to rs names, and concatenate into a string
	# also do all sub-paths ending in the sink nodes
	for my $path (@finishedPaths) {

		while (scalar(@{$path})) {

			push @hierarchies, join(',', @browsable[@{$path}]);
			shift @{$path};
		}
	}
	
	%validHierarchies = map {lc($_) => $_} @hierarchies;
}

sub isaTrack {
	my $obj = shift;
	
	return $obj && blessed $obj && ($obj->isa('Slim::Schema::Track') || $obj->isa('Slim::Schema::RemoteTrack'));
}

sub clearLastError {
	$LAST_ERROR = 'Unknown Error';
}

sub lastError { $LAST_ERROR }

sub totals {
	my $class = shift;
	
	if ( !exists $TOTAL_CACHE{album} ) {
		$TOTAL_CACHE{album} = $class->count('Album');
	}
	if ( !exists $TOTAL_CACHE{contributor} ) {
		$TOTAL_CACHE{contributor} = $class->rs('Contributor')->browse->count;
	}
	if ( !exists $TOTAL_CACHE{genre} ) {
		$TOTAL_CACHE{genre} = $class->count('Genre');
	}
	if ( !exists $TOTAL_CACHE{track} ) {
		# Bug 13215, this used to be $class->rs('Track')->browse->count but this generates a slow query
		my $dbh = Slim::Schema->storage->dbh;
		my $sth = $dbh->prepare_cached('SELECT COUNT(*) FROM tracks WHERE audio = 1');
		$sth->execute;
		($TOTAL_CACHE{track}) = $sth->fetchrow_array;
		$sth->finish;
	}
	
	return \%TOTAL_CACHE;
}

=head1 SEE ALSO

L<DBIx::Class>

L<DBIx::Class::Schema>

L<DBIx::Class::ResultSet>,

L<Slim::Schema::Track>

L<Slim::Schema::Playlist>

L<Slim::Music::Info>

L<DBIx::Migration>

=cut

1;

__END__