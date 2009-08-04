use strict;
use warnings;

use Test::More;
use Test::Exception;

use lib qw(t/lib);
use DBICTest;
use DBIC::SqlMakerTest;

my $schema = DBICTest->init_schema();
my $sdebug = $schema->storage->debug;

my $cd_rs = $schema->resultset('CD')->search (
  { 'tracks.cd' => { '!=', undef } },
  { prefetch => 'tracks' },
);

# Database sanity check
is($cd_rs->count, 5, 'CDs with tracks count');
for ($cd_rs->all) {
  is ($_->tracks->count, 3, '3 tracks for CD' . $_->id );
}

# Test a belongs_to prefetch of a has_many
{
  my $track_rs = $schema->resultset ('Track')->search (
    { 'me.cd' => { -in => [ $cd_rs->get_column ('cdid')->all ] } },
    {
      select => [
        'me.cd',
        { count => 'me.trackid' },
      ],
      as => [qw/
        cd
        track_count
      /],
      group_by => [qw/me.cd/],
      prefetch => 'cd',
    },
  );

  # this used to fuck up ->all, do not remove!
  ok ($track_rs->first, 'There is stuff in the rs');

  is($track_rs->count, 5, 'Prefetched count with groupby');
  is($track_rs->all, 5, 'Prefetched objects with groupby');

  {
    my $query_cnt = 0;
    $schema->storage->debugcb ( sub { $query_cnt++ } );
    $schema->storage->debug (1);

    while (my $collapsed_track = $track_rs->next) {
      my $cdid = $collapsed_track->get_column('cd');
      is($collapsed_track->get_column('track_count'), 3, "Correct count of tracks for CD $cdid" );
      ok($collapsed_track->cd->title, "Prefetched title for CD $cdid" );
    }

    is ($query_cnt, 1, 'Single query on prefetched titles');
    $schema->storage->debugcb (undef);
    $schema->storage->debug ($sdebug);
  }

  # Test sql by hand, as the sqlite db will simply paper over
  # improper group/select combinations
  #
  is_same_sql_bind (
    $track_rs->count_rs->as_query,
    '(
      SELECT COUNT( * )
        FROM (
          SELECT me.cd
            FROM track me
            JOIN cd cd ON cd.cdid = me.cd
          WHERE ( me.cd IN ( ?, ?, ?, ?, ? ) )
          GROUP BY me.cd
        )
      count_subq
    )',
    [ map { [ 'me.cd' => $_] } ($cd_rs->get_column ('cdid')->all) ],
    'count() query generated expected SQL',
  );

  is_same_sql_bind (
    $track_rs->as_query,
    '(
      SELECT me.cd, me.track_count, cd.cdid, cd.artist, cd.title, cd.year, cd.genreid, cd.single_track
        FROM (
          SELECT me.cd, COUNT (me.trackid) AS track_count,
            FROM track me
            JOIN cd cd ON cd.cdid = me.cd
          WHERE ( me.cd IN ( ?, ?, ?, ?, ? ) )
          GROUP BY me.cd
          ) as me
        JOIN cd cd ON cd.cdid = me.cd
      WHERE ( me.cd IN ( ?, ?, ?, ?, ? ) )
    )',
    [ map { [ 'me.cd' => $_] } ( ($cd_rs->get_column ('cdid')->all) x 2 ) ],
    'next() query generated expected SQL',
  );


  # add an extra track to one of the cds, and then make sure we can get it on top
  # (check if limit works)
  my $top_cd = $cd_rs->slice (1,1)->next;
  $top_cd->create_related ('tracks', {
    title => 'over the top',
  });

  my $top_cd_collapsed_track = $track_rs->search ({}, {
    rows => 2,
    order_by => [
      { -desc => 'track_count' },
    ],
  });

  is ($top_cd_collapsed_track->count, 2);

  is (
    $top_cd->title,
    $top_cd_collapsed_track->first->cd->title,
    'Correct collapsed track with prefetched CD returned on top'
  );
}

# test a has_many/might_have prefetch at the same level
# Note that one of the CDs now has 4 tracks instead of 3
{
  my $most_tracks_rs = $schema->resultset ('CD')->search (
    {
      'me.cdid' => { '!=' => undef },  # duh - this is just to test WHERE
    },
    {
      prefetch => [qw/tracks liner_notes/],
      select => ['me.cdid', { count => 'tracks.trackid' } ],
      as => [qw/cdid track_count/],
      group_by => 'me.cdid',
      order_by => { -desc => 'track_count' },
      rows => 2,
    }
  );

  is_same_sql_bind (
    $most_tracks_rs->count_rs->as_query,
    '(
      SELECT COUNT( * )
        FROM (
          SELECT me.cdid
            FROM cd me
            LEFT JOIN track tracks ON tracks.cd = me.cdid
            LEFT JOIN liner_notes liner_notes ON liner_notes.liner_id = me.cdid
          WHERE ( me.cdid IS NOT NULL )
          GROUP BY me.cdid
          LIMIT 2
        ) count_subq
    )',
    [],
    'count() query generated expected SQL',
  );

  is_same_sql_bind (
    $most_tracks_rs->as_query,
    '(
      SELECT me.cdid, me.track_count, tracks.trackid, tracks.cd, tracks.position, tracks.title, tracks.last_updated_on, tracks.last_updated_at, liner_notes.liner_id, liner_notes.notes
        FROM (
          SELECT me.cdid, COUNT( tracks.trackid ) AS track_count
            FROM cd me
            LEFT JOIN track tracks ON tracks.cd = me.cdid
          WHERE ( me.cdid IS NOT NULL )
          GROUP BY me.cdid
          ORDER BY track_count DESC
          LIMIT 2
        ) me
        LEFT JOIN track tracks ON tracks.cd = me.cdid
        LEFT JOIN liner_notes liner_notes ON liner_notes.liner_id = me.cdid
      WHERE ( me.cdid IS NOT NULL )
      ORDER BY track_count DESC, tracks.cd
    )',
    [],
    'next() query generated expected SQL',
  );

  is ($most_tracks_rs->count, 2, 'Limit works');
  my $top_cd = $most_tracks_rs->first;
  is ($top_cd->id, 2, 'Correct cd fetched on top'); # 2 because of the slice(1,1) earlier

  my $query_cnt = 0;
  $schema->storage->debugcb ( sub { $query_cnt++ } );
  $schema->storage->debug (1);

  is ($top_cd->get_column ('track_count'), 4, 'Track count fetched correctly');
  is ($top_cd->tracks->count, 4, 'Count of prefetched tracks rs still correct');
  is ($top_cd->tracks->all, 4, 'Number of prefetched track objects still correct');
  is (
    $top_cd->liner_notes->notes,
    'Buy Whiskey!',
    'Correct liner pre-fetched with top cd',
  );

  is ($query_cnt, 0, 'No queries executed during prefetched data access');
  $schema->storage->debugcb (undef);
  $schema->storage->debug ($sdebug);
}

# make sure that distinct still works
{
  my $rs = $schema->resultset("CD")->search({}, {
    prefetch => 'tags',
    order_by => 'cdid',
    distinct => 1,
  });

  is_same_sql_bind (
    $rs->as_query,
    '(
      SELECT me.cdid, me.artist, me.title, me.year, me.genreid, me.single_track,
             tags.tagid, tags.cd, tags.tag 
        FROM (
          SELECT me.cdid, me.artist, me.title, me.year, me.genreid, me.single_track
            FROM cd me
          GROUP BY me.cdid, me.artist, me.title, me.year, me.genreid, me.single_track
          ORDER BY cdid
        ) me
        LEFT JOIN tags tags ON tags.cd = me.cdid
      ORDER BY cdid, tags.cd, tags.tag
    )',
    [],
    'Prefetch + distinct resulted in correct group_by',
  );

  is ($rs->all, 5, 'Correct number of CD objects');
  is ($rs->count, 5, 'Correct count of CDs');
}

lives_ok (sub {
    my $rs = $schema->resultset("Artwork")->search(undef, {distinct => 1})
              ->search_related('artwork_to_artist')->search_related('artist',
                 undef,
                  { prefetch => q(cds) },
              );
    is($rs->all, 0, 'prefetch without WHERE');

    $rs = $schema->resultset("Artwork")->search(undef, {distinct => 1})
              ->search_related('artwork_to_artist')->search_related('artist',
                 { 'cds.title' => 'foo' },
                  { prefetch => q(cds) },
              );
    is($rs->all, 0, 'prefetch with WHERE');


    # different case
    $rs = $schema->resultset("Artist")->search(undef)
                ->search_related('cds')->search_related('genre',
                    { 'genre.name' => 'foo' },
                    { prefetch => q(cds) },
                 );
    is($rs->all, 0, 'prefetch without distinct');

    $rs = $schema->resultset("Artist")->search(undef, {distinct => 1})
                ->search_related('cds')->search_related('genre',
                    { 'genre.name' => 'foo' },
                 );
    is($rs->all, 0, 'distinct without prefetch');

    $rs = $schema->resultset("Artist")->search({artistid => '11'}, {distinct => 1})
                ->search_related('cds')->search_related('genre',
                    { 'genre.name' => 'foo' },
                    { prefetch => q(cds) },
                 );
    is($rs->all, 0, 'prefetch with distinct');
}, 'distinct generally works with prefetch');

done_testing;
