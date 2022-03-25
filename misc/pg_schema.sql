CREATE SCHEMA IF NOT EXISTS evergreen;

CREATE OR REPLACE FUNCTION
  evergreen.ts_from_epoch(INTEGER) RETURNS TIMESTAMP WITH TIME ZONE
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT TO_TIMESTAMP( $1 * 30 + 1598306400 )
$$;

CREATE OR REPLACE FUNCTION
  evergreen.expiration_cutoff() RETURNS TIMESTAMP WITH TIME ZONE
LANGUAGE sql PARALLEL RESTRICTED AS $$
  SELECT DATE_TRUNC( 'day', NOW() + '61 days'::INTERVAL )
$$;

CREATE OR REPLACE FUNCTION
  evergreen.max_program_replicas() RETURNS INTEGER
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT 10
$$;

CREATE OR REPLACE FUNCTION
  evergreen.max_per_city() RETURNS INTEGER
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT 1
$$;

CREATE OR REPLACE FUNCTION
  evergreen.max_per_country() RETURNS INTEGER
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT 2
$$;

CREATE OR REPLACE FUNCTION
  evergreen.max_per_continent() RETURNS INTEGER
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT 4
$$;

CREATE OR REPLACE FUNCTION
  evergreen.max_per_org() RETURNS INTEGER
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT 2
$$;


CREATE OR REPLACE
  FUNCTION evergreen.valid_cid_v1(TEXT) RETURNS BOOLEAN
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT SUBSTRING( $1 FROM 1 FOR 2 ) = 'ba'
$$;

CREATE OR REPLACE
  FUNCTION evergreen.update_entry_timestamp() RETURNS TRIGGER
    LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.entry_last_updated IS NULL THEN
    NEW.entry_last_updated = NOW();
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE
  FUNCTION evergreen.init_deal_related_actors() RETURNS TRIGGER
    LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO evergreen.clients( client_id ) VALUES ( NEW.client_id ) ON CONFLICT DO NOTHING;
  INSERT INTO evergreen.providers( provider_id ) VALUES ( NEW.provider_id ) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE
  FUNCTION evergreen.init_authed_sp() RETURNS TRIGGER
    LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO evergreen.providers( provider_id ) VALUES ( NEW.provider_id ) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;


CREATE TABLE IF NOT EXISTS evergreen.datasets (
  dataset_id SMALLSERIAL NOT NULL UNIQUE,
  dataset_slug TEXT NOT NULL UNIQUE,
  meta JSONB
);

CREATE TABLE IF NOT EXISTS evergreen.pieces (
  piece_cid TEXT NOT NULL UNIQUE CONSTRAINT valid_pcid CHECK ( evergreen.valid_cid_v1( piece_cid ) ),
  dataset_id SMALLINT NOT NULL REFERENCES evergreen.datasets ( dataset_id ),
  padded_size BIGINT NOT NULL CONSTRAINT valid_size CHECK ( padded_size > 0 ),
  meta JSONB
);
CREATE INDEX IF NOT EXISTS pieces_dataset_id_idx ON evergreen.pieces ( dataset_id );
CREATE INDEX IF NOT EXISTS pieces_padded_size_idx ON evergreen.pieces ( padded_size );

CREATE TABLE IF NOT EXISTS evergreen.payloads (
  piece_cid TEXT NOT NULL REFERENCES evergreen.pieces ( piece_cid ),
  payload_cid TEXT NOT NULL CONSTRAINT valid_rcid CHECK ( evergreen.valid_cid_v1( payload_cid ) ),
  CONSTRAINT payload_piece UNIQUE ( payload_cid, piece_cid ),
  CONSTRAINT temp_single_root UNIQUE ( piece_cid ),
  meta JSONB
);

CREATE TABLE IF NOT EXISTS evergreen.clients (
  client_id TEXT UNIQUE NOT NULL CONSTRAINT valid_id CHECK ( SUBSTRING( client_id FROM 1 FOR 2 ) IN ( 'f0', 't0' ) ),
  activateable_datacap BIGINT,
  is_affiliated BOOL NOT NULL DEFAULT false,
  client_address TEXT UNIQUE CONSTRAINT valid_client_address CHECK ( SUBSTRING( client_address FROM 1 FOR 2 ) IN ( 'f1', 'f3', 't1', 't3' ) ),
  meta JSONB,
  CONSTRAINT robust_affiliate CHECK (
    NOT is_affiliated
      OR
    client_address IS NOT NULL
  )
);
CREATE INDEX IF NOT EXISTS affiliated_clients ON evergreen.clients ( client_id ) WHERE is_affiliated;

CREATE TABLE IF NOT EXISTS evergreen.providers (
  provider_id TEXT NOT NULL UNIQUE CONSTRAINT valid_id CHECK ( SUBSTRING( provider_id FROM 1 FOR 2 ) IN ( 'f0', 't0' ) ),
  is_active BOOL NOT NULL DEFAULT false,
  meta JSONB,
  org_id TEXT NOT NULL DEFAULT '',
  city TEXT NOT NULL DEFAULT '',
  country TEXT NOT NULL DEFAULT '',
  continent TEXT NOT NULL DEFAULT '',
  CONSTRAINT valid_activation CHECK (
    ( NOT is_active )
     OR
    ( org_id != '' AND city != '' AND country != '' AND continent != '' )
  )
);

CREATE TABLE IF NOT EXISTS evergreen.requests (
  provider_id TEXT NOT NULL REFERENCES evergreen.providers ( provider_id ),
  request_uuid UUID UNIQUE NOT NULL DEFAULT gen_random_uuid(),
  entry_created TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  request_dump JSONB NOT NULL,
  meta JSONB
);
CREATE TRIGGER trigger_create_related_sp
  BEFORE INSERT ON evergreen.requests
  FOR EACH ROW
  EXECUTE PROCEDURE evergreen.init_authed_sp()
;


CREATE TABLE IF NOT EXISTS evergreen.published_deals (
  deal_id BIGINT UNIQUE NOT NULL CONSTRAINT valid_id CHECK ( deal_id > 0 ),
  piece_cid TEXT NOT NULL REFERENCES evergreen.pieces ( piece_cid ),
  provider_id TEXT NOT NULL REFERENCES evergreen.providers ( provider_id ),
  client_id TEXT NOT NULL REFERENCES evergreen.clients ( client_id ),
  label BYTEA NOT NULL,
  decoded_label TEXT CONSTRAINT valid_cid CHECK ( evergreen.valid_cid_v1( decoded_label ) ),
  is_fil_plus BOOL NOT NULL,
  status TEXT NOT NULL,
  status_meta TEXT,
  start_epoch INTEGER NOT NULL CONSTRAINT valid_start CHECK ( start_epoch > 0 ),
  start_time TIMESTAMP WITH TIME ZONE NOT NULL GENERATED ALWAYS AS ( evergreen.ts_from_epoch( start_epoch ) ) STORED,
  end_epoch INTEGER NOT NULL CONSTRAINT valid_end CHECK ( end_epoch > 0 ),
  end_time TIMESTAMP WITH TIME ZONE NOT NULL GENERATED ALWAYS AS ( evergreen.ts_from_epoch( end_epoch ) ) STORED,
  sector_start_epoch INTEGER CONSTRAINT valid_sector_start CHECK ( sector_start_epoch > 0 ),
  sector_start_time TIMESTAMP WITH TIME ZONE GENERATED ALWAYS AS ( evergreen.ts_from_epoch( sector_start_epoch ) ) STORED,
  termination_detection_time TIMESTAMP WITH TIME ZONE,
  entry_created TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  CONSTRAINT valid_termination_record CHECK ( (status = 'terminated') = (termination_detection_time IS NOT NULL) )
);
CREATE TRIGGER trigger_create_related_actors
  BEFORE INSERT ON evergreen.published_deals
  FOR EACH ROW
  EXECUTE PROCEDURE evergreen.init_deal_related_actors()
;
CREATE INDEX IF NOT EXISTS published_deals_piece_cid ON evergreen.published_deals ( piece_cid );
CREATE INDEX IF NOT EXISTS published_deals_client ON evergreen.published_deals ( client_id );
CREATE INDEX IF NOT EXISTS published_deals_provider ON evergreen.published_deals ( provider_id );
CREATE INDEX IF NOT EXISTS published_deals_status ON evergreen.published_deals ( status, is_fil_plus, piece_cid );
CREATE INDEX IF NOT EXISTS published_deals_sector_started ON evergreen.published_deals ( sector_start_epoch );


CREATE TABLE IF NOT EXISTS evergreen.proposals (
  piece_cid TEXT NOT NULL REFERENCES evergreen.pieces ( piece_cid ),
  provider_id TEXT NOT NULL REFERENCES evergreen.providers ( provider_id ),
  client_id TEXT NOT NULL REFERENCES evergreen.clients ( client_id ),

  dealstart_payload JSONB,
  start_by TIMESTAMP WITH TIME ZONE GENERATED ALWAYS AS ( evergreen.ts_from_epoch( (dealstart_payload->>'DealStartEpoch')::INTEGER ) ) STORED,

  proposal_success_cid TEXT UNIQUE CONSTRAINT valid_proposal_cid CHECK ( evergreen.valid_cid_v1(proposal_success_cid) ),
  proposal_failstamp BIGINT NOT NULL DEFAULT 0 CONSTRAINT valid_failstamp CHECK ( proposal_failstamp >= 0 ),

  activated_deal_id BIGINT REFERENCES evergreen.published_deals ( deal_id ),
  meta JSONB,

  entry_created TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  entry_last_updated TIMESTAMP WITH TIME ZONE NOT NULL,
  CONSTRAINT singleton_piece_record UNIQUE ( provider_id, piece_cid, proposal_failstamp ),
  CONSTRAINT no_fail_while_pending_activation CHECK ( proposal_success_cid IS NULL OR proposal_failstamp = 0 OR start_by <= entry_last_updated ),
  CONSTRAINT annotated_failure CHECK ( (proposal_failstamp = 0) = (meta->'failure' IS NULL) )
);
CREATE TRIGGER trigger_proposal_update_ts
  BEFORE INSERT OR UPDATE ON evergreen.proposals
  FOR EACH ROW
  EXECUTE PROCEDURE evergreen.update_entry_timestamp()
;
CREATE INDEX IF NOT EXISTS proposals_client_idx ON evergreen.proposals ( client_id );
CREATE INDEX IF NOT EXISTS proposals_provider_idx ON evergreen.proposals ( provider_id );
CREATE INDEX IF NOT EXISTS proposals_piece_idx ON evergreen.proposals ( piece_cid );

BEGIN;
DROP VIEW IF EXISTS deallist_v0;
DROP MATERIALIZED VIEW IF EXISTS counts_pending;
DROP MATERIALIZED VIEW IF EXISTS counts_replicas;
DROP MATERIALIZED VIEW IF EXISTS deallist_eligible;
DROP MATERIALIZED VIEW IF EXISTS known_org_ids;
DROP MATERIALIZED VIEW IF EXISTS known_cities;
DROP MATERIALIZED VIEW IF EXISTS known_countries;
DROP MATERIALIZED VIEW IF EXISTS known_continents;

CREATE MATERIALIZED VIEW known_org_ids AS ( SELECT DISTINCT( org_id ) FROM providers WHERE org_id != '' );
CREATE UNIQUE INDEX known_org_ids_key ON evergreen.known_org_ids ( org_id );
ANALYZE known_org_ids;

CREATE MATERIALIZED VIEW known_cities AS ( SELECT DISTINCT( city ) FROM providers WHERE city != '' );
CREATE UNIQUE INDEX known_cities_key ON evergreen.known_cities ( city );
ANALYZE known_cities;

CREATE MATERIALIZED VIEW known_countries AS ( SELECT DISTINCT( country ) FROM providers WHERE country != '' );
CREATE UNIQUE INDEX known_contries_key ON evergreen.known_countries ( country );
ANALYZE known_countries;

CREATE MATERIALIZED VIEW known_continents AS ( SELECT DISTINCT( continent ) FROM providers WHERE continent != '' );
CREATE UNIQUE INDEX known_continents_key ON evergreen.known_continents ( continent );
ANALYZE known_continents;


CREATE MATERIALIZED VIEW deallist_eligible AS (
  WITH
    pieces_for_refresh AS (
      SELECT
          pi.piece_cid,
          pi.padded_size,
          ds.dataset_slug
        FROM evergreen.pieces pi
        LEFT JOIN datasets ds USING ( dataset_id )
      WHERE
        -- there needs to be at least one active deal ( anywhere )
        EXISTS (
          SELECT 42
            FROM evergreen.published_deals d0
          WHERE
            d0.piece_cid = pi.piece_cid
              AND
            d0.status = 'active'
        )
          AND
        -- fewer than program-allowed total not-yet-expiring replicas ( not counting our proposals )
        max_program_replicas() > (
          SELECT COUNT(DISTINCT( d1.provider_id ))
            FROM evergreen.published_deals d1
            JOIN evergreen.clients c USING ( client_id )
          WHERE
            d1.piece_cid = pi.piece_cid
              AND
            c.is_affiliated
              AND
            d1.is_fil_plus
              AND
            d1.status = 'active'
              AND
            d1.end_time > expiration_cutoff()
        )
    ),
    deallist_with_dupes AS (
      SELECT
          d.deal_id,
          pfr.dataset_slug,
          pfr.piece_cid,
          pfr.padded_size,
          (
            CASE WHEN d.decoded_label = pl.payload_cid THEN CONVERT_FROM(d.label,'UTF-8') ELSE pl.payload_cid END
          ) AS original_payload_cid,
          pl.payload_cid AS normalized_payload_cid,
          d.status,
          d.provider_id,
          c.client_address,
          d.is_fil_plus,
          d.start_epoch,
          d.start_time,
          d.end_epoch,
          d.end_time,
          ( RANK() OVER ( PARTITION BY pfr.piece_cid, d.provider_id ORDER BY d.is_fil_plus DESC, d.end_time DESC, d.deal_id ) ) AS sp_best_deal_rank
        FROM pieces_for_refresh pfr
        JOIN evergreen.payloads pl USING ( piece_cid )
        JOIN evergreen.published_deals d USING ( piece_cid )
        JOIN evergreen.clients c USING ( client_id )
      WHERE
        d.status = 'active'
    )
  SELECT
      d.deal_id,
      d.dataset_slug,
      d.piece_cid,
      d.padded_size,
      d.original_payload_cid,
      d.normalized_payload_cid,
      d.status,
      d.start_epoch,
      d.start_time,
      d.end_epoch,
      d.end_time,
      d.client_address,
      d.is_fil_plus,
      d.provider_id,
      pr.org_id,
      pr.city,
      pr.country,
      pr.continent
    FROM deallist_with_dupes d
    JOIN evergreen.providers pr USING ( provider_id )
  WHERE sp_best_deal_rank = 1
);
CREATE UNIQUE INDEX deallist_eligible_deal_id ON evergreen.deallist_eligible ( deal_id );
CREATE INDEX deallist_eligible_piece_cid ON evergreen.deallist_eligible ( piece_cid );
CREATE INDEX deallist_eligible_original_payload_cid ON evergreen.deallist_eligible ( original_payload_cid );
CREATE INDEX deallist_eligible_normalized_payload_cid ON evergreen.deallist_eligible ( normalized_payload_cid );
CREATE INDEX deallist_eligible_padded_size ON evergreen.deallist_eligible ( padded_size );
CREATE INDEX deallist_eligible_provider_id ON evergreen.deallist_eligible ( provider_id );
CREATE INDEX deallist_eligible_is_fil_plus ON evergreen.deallist_eligible ( is_fil_plus );
CREATE INDEX deallist_eligible_start_time ON evergreen.deallist_eligible ( start_time );
CREATE INDEX deallist_eligible_end_time ON evergreen.deallist_eligible ( end_time );
CREATE INDEX deallist_eligible_org_id ON evergreen.deallist_eligible ( org_id );
CREATE INDEX deallist_eligible_city ON evergreen.deallist_eligible ( city );
CREATE INDEX deallist_eligible_country ON evergreen.deallist_eligible ( country );
CREATE INDEX deallist_eligible_continent ON evergreen.deallist_eligible ( continent );
ANALYZE evergreen.deallist_eligible;

CREATE MATERIALIZED VIEW counts_replicas AS (
  SELECT
    curpiece.piece_cid,
    (
      SELECT JSONB_OBJECT_AGG( k,v ) FROM (
        (
          SELECT 'total' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT 'total' AS k,
            (
              SELECT COUNT(*)
                FROM published_deals d
                JOIN clients c USING ( client_id )
              WHERE
                d.piece_cid = curpiece.piece_cid
                  AND
                d.end_time > expiration_cutoff()
                  AND
                d.status = 'active'
                  AND
                c.is_affiliated
            ) AS v
          ) sagg ) AS v
        )
          UNION ALL
        (
          SELECT 'org_id' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT
              curkey.org_id AS k,
              (
                SELECT COUNT(*)
                  FROM published_deals d
                  JOIN clients c USING ( client_id )
                  JOIN providers p USING ( provider_id )
                WHERE
                  d.piece_cid = curpiece.piece_cid
                    AND
                  d.end_time > expiration_cutoff()
                    AND
                  d.status = 'active'
                    AND
                  c.is_affiliated
                    AND
                  p.org_id = curkey.org_id
              ) AS v
            FROM known_org_ids curkey
          ) sagg ) AS v
        )
          UNION ALL
        (
          SELECT 'city' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT
              curkey.city AS k,
              (
                SELECT COUNT(*)
                  FROM published_deals d
                  JOIN clients c USING ( client_id )
                  JOIN providers p USING ( provider_id )
                WHERE
                  d.piece_cid = curpiece.piece_cid
                    AND
                  d.end_time > expiration_cutoff()
                    AND
                  d.status = 'active'
                    AND
                  c.is_affiliated
                    AND
                  p.city = curkey.city
              ) AS v
            FROM known_cities curkey
          ) sagg ) AS v
        )
          UNION ALL
        (
          SELECT 'country' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT
              curkey.country AS k,
              (
                SELECT COUNT(*)
                  FROM published_deals d
                  JOIN clients c USING ( client_id )
                  JOIN providers p USING ( provider_id )
                WHERE
                  d.piece_cid = curpiece.piece_cid
                    AND
                  d.end_time > expiration_cutoff()
                    AND
                  d.status = 'active'
                    AND
                  c.is_affiliated
                    AND
                  p.country = curkey.country
              ) AS v
            FROM known_countries curkey
          ) sagg ) AS v
        )
          UNION ALL
        (
          SELECT 'continent' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT
              curkey.continent AS k,
              (
                SELECT COUNT(*)
                  FROM published_deals d
                  JOIN clients c USING ( client_id )
                  JOIN providers p USING ( provider_id )
                WHERE
                  d.piece_cid = curpiece.piece_cid
                    AND
                  d.end_time > expiration_cutoff()
                    AND
                  d.status = 'active'
                    AND
                  c.is_affiliated
                    AND
                  p.continent = curkey.continent
              ) AS v
            FROM known_continents curkey
          ) sagg ) AS v
        )
      ) agg
    ) AS counts
  FROM pieces curpiece
);
CREATE UNIQUE INDEX counts_replicas_piece_cid ON evergreen.counts_replicas ( piece_cid );
ANALYZE evergreen.counts_replicas;

CREATE MATERIALIZED VIEW counts_pending AS (
  SELECT
    curpiece.piece_cid,
    (
      SELECT JSONB_OBJECT_AGG( k,v ) FROM (
        (
          SELECT 'total' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT 'total' AS k,
            (
              SELECT COUNT(*)
                FROM proposals pr
              WHERE
                pr.piece_cid = curpiece.piece_cid
                  AND
                pr.proposal_failstamp = 0
                  AND
                pr.activated_deal_id IS NULL
            ) AS v
          ) sagg ) AS v
        )
          UNION ALL
        (
          SELECT 'org_id' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT
              curkey.org_id AS k,
              (
                SELECT COUNT(*)
                  FROM proposals pr
                  JOIN providers p USING ( provider_id )
                WHERE
                  pr.piece_cid = curpiece.piece_cid
                    AND
                  pr.proposal_failstamp = 0
                    AND
                  pr.activated_deal_id IS NULL
                    AND
                  p.org_id = curkey.org_id
              ) AS v
            FROM known_org_ids curkey
          ) sagg ) AS v
        )
          UNION ALL
        (
          SELECT 'city' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT
              curkey.city AS k,
              (
                SELECT COUNT(*)
                  FROM proposals pr
                  JOIN providers p USING ( provider_id )
                WHERE
                  pr.piece_cid = curpiece.piece_cid
                    AND
                  pr.proposal_failstamp = 0
                    AND
                  pr.activated_deal_id IS NULL
                    AND
                  p.city = curkey.city
              ) AS v
            FROM known_cities curkey
          ) sagg ) AS v
        )
          UNION ALL
        (
          SELECT 'country' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT
              curkey.country AS k,
              (
                SELECT COUNT(*)
                  FROM proposals pr
                  JOIN providers p USING ( provider_id )
                WHERE
                  pr.piece_cid = curpiece.piece_cid
                    AND
                  pr.proposal_failstamp = 0
                    AND
                  pr.activated_deal_id IS NULL
                    AND
                  p.country = curkey.country
              ) AS v
            FROM known_countries curkey
          ) sagg ) AS v
        )
          UNION ALL
        (
          SELECT 'continent' AS k, ( SELECT JSONB_OBJECT_AGG( k,v ) FROM (
            SELECT
              curkey.continent AS k,
              (
                SELECT COUNT(*)
                  FROM proposals pr
                  JOIN providers p USING ( provider_id )
                WHERE
                  pr.piece_cid = curpiece.piece_cid
                    AND
                  pr.proposal_failstamp = 0
                    AND
                  pr.activated_deal_id IS NULL
                    AND
                  p.continent = curkey.continent
              ) AS v
            FROM known_continents curkey
          ) sagg ) AS v
        )
      ) agg
    ) AS counts
  FROM pieces curpiece
);
CREATE UNIQUE INDEX counts_pending_piece_cid ON evergreen.counts_pending ( piece_cid );
ANALYZE evergreen.counts_pending;


CREATE VIEW deallist_v0 AS (
  SELECT
    deal_id,
    dataset_slug,
    piece_cid,
    padded_size,
    original_payload_cid AS payload_cid,
    provider_id,
    client_address,
    is_fil_plus,
    start_epoch,
    start_time,
    end_epoch,
    end_time
  FROM deallist_eligible
);

COMMIT;
