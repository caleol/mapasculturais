--
-- PostgreSQL database dump
--

-- Dumped from database version 9.6.1
-- Dumped by pg_dump version 9.6.1

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: plpgsql; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plpgsql; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL procedural language';


--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry, geography, and raster spatial types and functions';


--
-- Name: unaccent; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;


--
-- Name: EXTENSION unaccent; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION unaccent IS 'text search dictionary that removes accents';


SET search_path = public, pg_catalog;

--
-- Name: frequency; Type: DOMAIN; Schema: public; Owner: -
--

CREATE DOMAIN frequency AS character varying
	CONSTRAINT frequency_check CHECK (((VALUE)::text = ANY (ARRAY[('once'::character varying)::text, ('daily'::character varying)::text, ('weekly'::character varying)::text, ('monthly'::character varying)::text, ('yearly'::character varying)::text])));


--
-- Name: days_in_month(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION days_in_month(check_date date) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  first_of_month DATE := check_date - ((extract(day from check_date) - 1)||' days')::interval;
BEGIN
  RETURN extract(day from first_of_month + '1 month'::interval - first_of_month);
END;
$$;


--
-- Name: generate_recurrences(interval, date, date, date, date, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION generate_recurrences(duration interval, original_start_date date, original_end_date date, range_start date, range_end date, repeat_month integer, repeat_week integer, repeat_day integer) RETURNS SETOF date
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  start_date DATE := original_start_date;
  next_date DATE;
  intervals INT := FLOOR(intervals_between(original_start_date, range_start, duration));
  current_month INT;
  current_week INT;
BEGIN
  IF repeat_month IS NOT NULL THEN
    start_date := start_date + (((12 + repeat_month - cast(extract(month from start_date) as int)) % 12) || ' months')::interval;
  END IF;
  IF repeat_week IS NULL AND repeat_day IS NOT NULL THEN
    IF duration = '7 days'::interval THEN
      start_date := start_date + (((7 + repeat_day - cast(extract(dow from start_date) as int)) % 7) || ' days')::interval;
    ELSE
      start_date := start_date + (repeat_day - extract(day from start_date) || ' days')::interval;
    END IF;
  END IF;
  LOOP
    next_date := start_date + duration * intervals;
    IF repeat_week IS NOT NULL AND repeat_day IS NOT NULL THEN
      current_month := extract(month from next_date);
      next_date := next_date + (((7 + repeat_day - cast(extract(dow from next_date) as int)) % 7) || ' days')::interval;
      IF extract(month from next_date) != current_month THEN
        next_date := next_date - '7 days'::interval;
      END IF;
      IF repeat_week > 0 THEN
        current_week := CEIL(extract(day from next_date) / 7);
      ELSE
        current_week := -CEIL((1 + days_in_month(next_date) - extract(day from next_date)) / 7);
      END IF;
      next_date := next_date + (repeat_week - current_week) * '7 days'::interval;
    END IF;
    EXIT WHEN next_date > range_end;

    IF next_date >= range_start AND next_date >= original_start_date THEN
      RETURN NEXT next_date;
    END IF;

    if original_end_date IS NOT NULL AND range_start >= original_start_date + (duration*intervals) AND range_start <= original_end_date + (duration*intervals) THEN
      RETURN NEXT next_date;
    END IF;
    intervals := intervals + 1;
  END LOOP;
END;
$$;


--
-- Name: interval_for(frequency); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION interval_for(recurs frequency) RETURNS interval
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
  IF recurs = 'daily' THEN
    RETURN '1 day'::interval;
  ELSIF recurs = 'weekly' THEN
    RETURN '7 days'::interval;
  ELSIF recurs = 'monthly' THEN
    RETURN '1 month'::interval;
  ELSIF recurs = 'yearly' THEN
    RETURN '1 year'::interval;
  ELSE
    RAISE EXCEPTION 'Recurrence % not supported by generate_recurrences()', recurs;
  END IF;
END;
$$;


--
-- Name: intervals_between(date, date, interval); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION intervals_between(start_date date, end_date date, duration interval) RETURNS double precision
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  count FLOAT := 0;
  multiplier INT := 512;
BEGIN
  IF start_date > end_date THEN
    RETURN 0;
  END IF;
  LOOP
    WHILE start_date + (count + multiplier) * duration < end_date LOOP
      count := count + multiplier;
    END LOOP;
    EXIT WHEN multiplier = 1;
    multiplier := multiplier / 2;
  END LOOP;
  count := count + (extract(epoch from end_date) - extract(epoch from (start_date + count * duration))) / (extract(epoch from end_date + duration) - extract(epoch from end_date))::int;
  RETURN count;
END
$$;


--
-- Name: pseudo_random_id_generator(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION pseudo_random_id_generator() RETURNS integer
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
                DECLARE
                    l1 int;
                    l2 int;
                    r1 int;
                    r2 int;
                    VALUE int;
                    i int:=0;
                BEGIN
                    VALUE:= nextval('pseudo_random_id_seq');
                    l1:= (VALUE >> 16) & 65535;
                    r1:= VALUE & 65535;
                    WHILE i < 3 LOOP
                        l2 := r1;
                        r2 := l1 # ((((1366 * r1 + 150889) % 714025) / 714025.0) * 32767)::int;
                        l1 := l2;
                        r1 := r2;
                        i := i + 1;
                    END LOOP;
                    RETURN ((r1 << 16) + l1);
                END;
            $$;


--
-- Name: random_id_generator(character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION random_id_generator(table_name character varying, initial_range bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$DECLARE
              rand_int INTEGER;
              count INTEGER := 1;
              statement TEXT;
            BEGIN
              WHILE count > 0 LOOP
                initial_range := initial_range * 10;

                rand_int := (RANDOM() * initial_range)::BIGINT + initial_range / 10;

                statement := CONCAT('SELECT count(id) FROM ', table_name, ' WHERE id = ', rand_int);

                EXECUTE statement;
                IF NOT FOUND THEN
                  count := 0;
                END IF;

              END LOOP;
              RETURN rand_int;
            END;
            $$;


SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: event_occurrence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE event_occurrence (
    id integer NOT NULL,
    space_id integer NOT NULL,
    event_id integer NOT NULL,
    rule text,
    starts_on date,
    ends_on date,
    starts_at timestamp without time zone,
    ends_at timestamp without time zone,
    frequency frequency,
    separation integer DEFAULT 1 NOT NULL,
    count integer,
    until date,
    timezone_name text DEFAULT 'Etc/UTC'::text NOT NULL,
    status integer DEFAULT 1 NOT NULL,
    CONSTRAINT positive_separation CHECK ((separation > 0))
);


--
-- Name: recurrences_for(event_occurrence, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION recurrences_for(event event_occurrence, range_start timestamp without time zone, range_end timestamp without time zone) RETURNS SETOF date
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  recurrence event_occurrence_recurrence;
  recurrences_start DATE := COALESCE(event.starts_at::date, event.starts_on);
  recurrences_end DATE := range_end;
  duration INTERVAL := interval_for(event.frequency) * event.separation;
  next_date DATE;
BEGIN
  IF event.until IS NOT NULL AND event.until < recurrences_end THEN
    recurrences_end := event.until;
  END IF;
  IF event.count IS NOT NULL AND recurrences_start + (event.count - 1) * duration < recurrences_end THEN
    recurrences_end := recurrences_start + (event.count - 1) * duration;
  END IF;

  FOR recurrence IN
    SELECT event_occurrence_recurrence.*
      FROM (SELECT NULL) AS foo
      LEFT JOIN event_occurrence_recurrence
        ON event_occurrence_id = event.id
  LOOP
    FOR next_date IN
      SELECT *
        FROM generate_recurrences(
          duration,
          recurrences_start,
          COALESCE(event.ends_at::date, event.ends_on),
          range_start::date,
          recurrences_end,
          recurrence.month,
          recurrence.week,
          recurrence.day
        )
    LOOP
      RETURN NEXT next_date;
    END LOOP;
  END LOOP;
  RETURN;
END;
$$;


--
-- Name: recurring_event_occurrence_for(timestamp without time zone, timestamp without time zone, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION recurring_event_occurrence_for(range_start timestamp without time zone, range_end timestamp without time zone, time_zone character varying, event_occurrence_limit integer) RETURNS SETOF event_occurrence
    LANGUAGE plpgsql STABLE
    AS $$
            DECLARE
              event event_occurrence;
              original_date DATE;
              original_date_in_zone DATE;
              start_time TIME;
              start_time_in_zone TIME;
              next_date DATE;
              next_time_in_zone TIME;
              duration INTERVAL;
              time_offset INTERVAL;
              r_start DATE := (timezone('UTC', range_start) AT TIME ZONE time_zone)::DATE;
              r_end DATE := (timezone('UTC', range_end) AT TIME ZONE time_zone)::DATE;

              recurrences_start DATE := CASE WHEN r_start < range_start THEN r_start ELSE range_start END;
              recurrences_end DATE := CASE WHEN r_end > range_end THEN r_end ELSE range_end END;

              inc_interval INTERVAL := '2 hours'::INTERVAL;

              ext_start TIMESTAMP := range_start::TIMESTAMP - inc_interval;
              ext_end   TIMESTAMP := range_end::TIMESTAMP   + inc_interval;
            BEGIN
              FOR event IN
                SELECT *
                  FROM event_occurrence
                  WHERE
                    status > 0
                    AND
                    (
                      (frequency = 'once' AND
                      ((starts_on IS NOT NULL AND ends_on IS NOT NULL AND starts_on <= r_end AND ends_on >= r_start) OR
                       (starts_on IS NOT NULL AND starts_on <= r_end AND starts_on >= r_start) OR
                       (starts_at <= range_end AND ends_at >= range_start)))

                      OR

                      (
                        frequency <> 'once' AND
                        (
                          ( starts_on IS NOT NULL AND starts_on <= ext_end ) OR
                          ( starts_at IS NOT NULL AND starts_at <= ext_end )
                        ) AND (
                          (until IS NULL AND ends_at IS NULL AND ends_on IS NULL) OR
                          (until IS NOT NULL AND until >= ext_start) OR
                          (ends_on IS NOT NULL AND ends_on >= ext_start) OR
                          (ends_at IS NOT NULL AND ends_at >= ext_start)
                        )
                      )
                    )

              LOOP
                IF event.frequency = 'once' THEN
                  RETURN NEXT event;
                  CONTINUE;
                END IF;

                -- All-day event
                IF event.starts_on IS NOT NULL AND event.ends_on IS NULL THEN
                  original_date := event.starts_on;
                  duration := '1 day'::interval;
                -- Multi-day event
                ELSIF event.starts_on IS NOT NULL AND event.ends_on IS NOT NULL THEN
                  original_date := event.starts_on;
                  duration := timezone(time_zone, event.ends_on) - timezone(time_zone, event.starts_on);
                -- Timespan event
                ELSE
                  original_date := event.starts_at::date;
                  original_date_in_zone := (timezone('UTC', event.starts_at) AT TIME ZONE event.timezone_name)::date;
                  start_time := event.starts_at::time;
                  start_time_in_zone := (timezone('UTC', event.starts_at) AT time ZONE event.timezone_name)::time;
                  duration := event.ends_at - event.starts_at;
                END IF;

                IF event.count IS NOT NULL THEN
                  recurrences_start := original_date;
                END IF;

                FOR next_date IN
                  SELECT occurrence
                    FROM (
                      SELECT * FROM recurrences_for(event, recurrences_start, recurrences_end) AS occurrence
                      UNION SELECT original_date
                      LIMIT event.count
                    ) AS occurrences
                    WHERE
                      occurrence::date <= recurrences_end AND
                      (occurrence + duration)::date >= recurrences_start AND
                      occurrence NOT IN (SELECT date FROM event_occurrence_cancellation WHERE event_occurrence_id = event.id)
                    LIMIT event_occurrence_limit
                LOOP
                  -- All-day event
                  IF event.starts_on IS NOT NULL AND event.ends_on IS NULL THEN
                    CONTINUE WHEN next_date < r_start OR next_date > r_end;
                    event.starts_on := next_date;

                  -- Multi-day event
                  ELSIF event.starts_on IS NOT NULL AND event.ends_on IS NOT NULL THEN
                    event.starts_on := next_date;
                    CONTINUE WHEN event.starts_on > r_end;
                    event.ends_on := next_date + duration;
                    CONTINUE WHEN event.ends_on < r_start;

                  -- Timespan event
                  ELSE
                    next_time_in_zone := (timezone('UTC', (next_date + start_time)) at time zone event.timezone_name)::time;
                    time_offset := (original_date_in_zone + next_time_in_zone) - (original_date_in_zone + start_time_in_zone);
                    event.starts_at := next_date + start_time - time_offset;

                    CONTINUE WHEN event.starts_at > range_end;
                    event.ends_at := event.starts_at + duration;
                    CONTINUE WHEN event.ends_at < range_start;
                  END IF;

                  RETURN NEXT event;
                END LOOP;
              END LOOP;
              RETURN;
            END;
            $$;


--
-- Name: _mesoregiao; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE _mesoregiao (
    gid integer NOT NULL,
    id double precision,
    nm_meso character varying(100),
    cd_geocodu character varying(2),
    geom geometry(MultiPolygon,4326)
);


--
-- Name: _mesoregiao_gid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE _mesoregiao_gid_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: _mesoregiao_gid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE _mesoregiao_gid_seq OWNED BY _mesoregiao.gid;


--
-- Name: _microregiao; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE _microregiao (
    gid integer NOT NULL,
    id double precision,
    nm_micro character varying(100),
    cd_geocodu character varying(2),
    geom geometry(MultiPolygon,4326)
);


--
-- Name: _microregiao_gid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE _microregiao_gid_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: _microregiao_gid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE _microregiao_gid_seq OWNED BY _microregiao.gid;


--
-- Name: _municipios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE _municipios (
    gid integer NOT NULL,
    id double precision,
    cd_geocodm character varying(20),
    nm_municip character varying(60),
    geom geometry(MultiPolygon,4326)
);


--
-- Name: _municipios_gid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE _municipios_gid_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: _municipios_gid_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE _municipios_gid_seq OWNED BY _municipios.gid;


--
-- Name: agent_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE agent_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE agent (
    id integer DEFAULT nextval('agent_id_seq'::regclass) NOT NULL,
    parent_id integer,
    user_id integer NOT NULL,
    type smallint NOT NULL,
    name character varying(255) NOT NULL,
    location point,
    _geo_location geography,
    short_description text,
    long_description text,
    create_timestamp timestamp without time zone NOT NULL,
    status smallint NOT NULL,
    is_verified boolean DEFAULT false NOT NULL,
    public_location boolean,
    update_timestamp timestamp(0) without time zone
);


--
-- Name: COLUMN agent.location; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN agent.location IS 'type=POINT';


--
-- Name: agent_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE agent_meta (
    object_id integer NOT NULL,
    key character varying(128) NOT NULL,
    value text,
    id integer NOT NULL
);


--
-- Name: agent_meta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE agent_meta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_meta_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE agent_meta_id_seq OWNED BY agent_meta.id;


--
-- Name: agent_relation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE agent_relation (
    id integer NOT NULL,
    agent_id integer NOT NULL,
    object_type character varying(255) NOT NULL,
    object_id integer NOT NULL,
    type character varying(64),
    has_control boolean DEFAULT false NOT NULL,
    create_timestamp timestamp without time zone,
    status smallint
);


--
-- Name: agent_relation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE agent_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_relation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE agent_relation_id_seq OWNED BY agent_relation.id;


--
-- Name: db_update; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE db_update (
    name character varying(255) NOT NULL,
    exec_time timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE event (
    id integer NOT NULL,
    project_id integer,
    name character varying(255) NOT NULL,
    short_description text NOT NULL,
    long_description text,
    rules text,
    create_timestamp timestamp without time zone NOT NULL,
    status smallint NOT NULL,
    agent_id integer,
    is_verified boolean DEFAULT false NOT NULL,
    type smallint NOT NULL,
    update_timestamp timestamp(0) without time zone
);


--
-- Name: event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE event_id_seq OWNED BY event.id;


--
-- Name: event_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE event_meta (
    key character varying(128) NOT NULL,
    object_id integer NOT NULL,
    value text,
    id integer NOT NULL
);


--
-- Name: event_meta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE event_meta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: event_meta_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE event_meta_id_seq OWNED BY event_meta.id;


--
-- Name: event_occurrence_cancellation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE event_occurrence_cancellation (
    id integer NOT NULL,
    event_occurrence_id integer,
    date date
);


--
-- Name: event_occurrence_cancellation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE event_occurrence_cancellation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: event_occurrence_cancellation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE event_occurrence_cancellation_id_seq OWNED BY event_occurrence_cancellation.id;


--
-- Name: event_occurrence_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE event_occurrence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: event_occurrence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE event_occurrence_id_seq OWNED BY event_occurrence.id;


--
-- Name: event_occurrence_recurrence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE event_occurrence_recurrence (
    id integer NOT NULL,
    event_occurrence_id integer,
    month integer,
    day integer,
    week integer
);


--
-- Name: event_occurrence_recurrence_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE event_occurrence_recurrence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: event_occurrence_recurrence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE event_occurrence_recurrence_id_seq OWNED BY event_occurrence_recurrence.id;


--
-- Name: file_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE file_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: file; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE file (
    id integer DEFAULT nextval('file_id_seq'::regclass) NOT NULL,
    md5 character varying(32) NOT NULL,
    mime_type character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    object_type character varying(255) NOT NULL,
    object_id integer NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    grp character varying(32) NOT NULL,
    description character varying(255),
    parent_id integer
);


--
-- Name: geo_division_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE geo_division_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: geo_division; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE geo_division (
    id integer DEFAULT nextval('geo_division_id_seq'::regclass) NOT NULL,
    parent_id integer,
    type character varying(32) NOT NULL,
    cod character varying(32),
    name character varying(128) NOT NULL,
    geom geometry,
    CONSTRAINT enforce_dims_geom CHECK ((st_ndims(geom) = 2)),
    CONSTRAINT enforce_geotype_geom CHECK (((geometrytype(geom) = 'MULTIPOLYGON'::text) OR (geom IS NULL))),
    CONSTRAINT enforce_srid_geom CHECK ((st_srid(geom) = 4326))
);


--
-- Name: metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE metadata (
    object_id integer NOT NULL,
    object_type character varying(255) NOT NULL,
    key character varying(32) NOT NULL,
    value text
);


--
-- Name: metalist_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE metalist_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: metalist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE metalist (
    id integer DEFAULT nextval('metalist_id_seq'::regclass) NOT NULL,
    object_type character varying(255) NOT NULL,
    object_id integer NOT NULL,
    grp character varying(32) NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    value character varying(2048) NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    "order" smallint
);


--
-- Name: notification_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE notification_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notification; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE notification (
    id integer DEFAULT nextval('notification_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    request_id integer,
    message text NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    action_timestamp timestamp without time zone,
    status smallint NOT NULL
);


--
-- Name: occurrence_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE occurrence_id_seq
    START WITH 100000
    INCREMENT BY 1
    MINVALUE 100000
    NO MAXVALUE
    CACHE 1
    CYCLE;


--
-- Name: project; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE project (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    short_description text,
    long_description text,
    create_timestamp timestamp without time zone NOT NULL,
    status smallint NOT NULL,
    agent_id integer,
    is_verified boolean DEFAULT false NOT NULL,
    type smallint NOT NULL,
    parent_id integer,
    registration_from timestamp without time zone,
    registration_to timestamp without time zone,
    registration_categories text,
    use_registrations boolean DEFAULT false NOT NULL,
    published_registrations boolean DEFAULT false NOT NULL,
    update_timestamp timestamp(0) without time zone
);


--
-- Name: project_event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE project_event (
    id integer NOT NULL,
    event_id integer NOT NULL,
    project_id integer NOT NULL,
    type smallint NOT NULL,
    status smallint NOT NULL
);


--
-- Name: project_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE project_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE project_event_id_seq OWNED BY project_event.id;


--
-- Name: project_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE project_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE project_id_seq OWNED BY project.id;


--
-- Name: project_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE project_meta (
    object_id integer NOT NULL,
    key character varying(128) NOT NULL,
    value text,
    id integer NOT NULL
);


--
-- Name: project_meta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE project_meta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_meta_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE project_meta_id_seq OWNED BY project_meta.id;


--
-- Name: pseudo_random_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE pseudo_random_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: registration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE registration (
    id integer NOT NULL,
    project_id integer NOT NULL,
    category character varying(255),
    agent_id integer NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    sent_timestamp timestamp without time zone,
    status integer NOT NULL,
    agents_data text
);


--
-- Name: registration_field_configuration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE registration_field_configuration (
    id integer NOT NULL,
    project_id integer,
    title character varying(255) NOT NULL,
    description text,
    categories text,
    required boolean NOT NULL,
    field_type character varying(255) NOT NULL,
    field_options text NOT NULL
);


--
-- Name: COLUMN registration_field_configuration.categories; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN registration_field_configuration.categories IS '(DC2Type:array)';


--
-- Name: registration_field_configuration_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE registration_field_configuration_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: registration_file_configuration; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE registration_file_configuration (
    id integer NOT NULL,
    project_id integer,
    title character varying(255) NOT NULL,
    description text,
    required boolean NOT NULL,
    categories text
);


--
-- Name: COLUMN registration_file_configuration.categories; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN registration_file_configuration.categories IS '(DC2Type:array)';


--
-- Name: registration_file_configuration_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE registration_file_configuration_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: registration_file_configuration_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE registration_file_configuration_id_seq OWNED BY registration_file_configuration.id;


--
-- Name: registration_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE registration_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: registration_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE registration_meta (
    object_id integer NOT NULL,
    key character varying(32) NOT NULL,
    value text,
    id integer NOT NULL
);


--
-- Name: registration_meta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE registration_meta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: registration_meta_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE registration_meta_id_seq OWNED BY registration_meta.id;


--
-- Name: request_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE request_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: request; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE request (
    id integer DEFAULT nextval('request_id_seq'::regclass) NOT NULL,
    request_uid character varying(32) NOT NULL,
    requester_user_id integer NOT NULL,
    origin_type character varying(255) NOT NULL,
    origin_id integer NOT NULL,
    destination_type character varying(255) NOT NULL,
    destination_id integer NOT NULL,
    metadata text,
    type character varying(255) NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    action_timestamp timestamp without time zone,
    status smallint NOT NULL
);


--
-- Name: role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE role (
    id integer NOT NULL,
    usr_id integer NOT NULL,
    name character varying(32) NOT NULL
);


--
-- Name: role_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE role_id_seq OWNED BY role.id;


--
-- Name: seal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE seal (
    id integer NOT NULL,
    agent_id integer NOT NULL,
    name character varying(255) NOT NULL,
    short_description text,
    long_description text,
    valid_period smallint NOT NULL,
    create_timestamp timestamp(0) without time zone NOT NULL,
    status smallint NOT NULL,
    certificate_text text,
    update_timestamp timestamp(0) without time zone
);


--
-- Name: seal_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE seal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seal_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE seal_meta (
    id integer NOT NULL,
    object_id integer,
    key character varying(255) NOT NULL,
    value text
);


--
-- Name: seal_meta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE seal_meta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seal_relation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE seal_relation (
    id integer NOT NULL,
    seal_id integer,
    object_id integer NOT NULL,
    create_timestamp timestamp(0) without time zone DEFAULT NULL::timestamp without time zone,
    status smallint,
    object_type character varying(255) NOT NULL,
    agent_id integer NOT NULL,
    owner_id integer
);


--
-- Name: seal_relation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE seal_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: space; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE space (
    id integer NOT NULL,
    parent_id integer,
    location point,
    _geo_location geography,
    name character varying(255) NOT NULL,
    short_description text,
    long_description text,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    status smallint NOT NULL,
    type smallint NOT NULL,
    agent_id integer,
    is_verified boolean DEFAULT false NOT NULL,
    public boolean DEFAULT false NOT NULL,
    update_timestamp timestamp(0) without time zone
);


--
-- Name: COLUMN space.location; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN space.location IS 'type=POINT';


--
-- Name: space_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE space_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: space_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE space_id_seq OWNED BY space.id;


--
-- Name: space_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE space_meta (
    object_id integer NOT NULL,
    key character varying(128) NOT NULL,
    value text,
    id integer NOT NULL
);


--
-- Name: space_meta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE space_meta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: space_meta_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE space_meta_id_seq OWNED BY space_meta.id;


--
-- Name: term; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE term (
    id integer NOT NULL,
    taxonomy smallint DEFAULT 1 NOT NULL,
    term character varying(255) NOT NULL,
    description text
);


--
-- Name: COLUMN term.taxonomy; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN term.taxonomy IS '1=tag';


--
-- Name: term_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE term_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: term_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE term_id_seq OWNED BY term.id;


--
-- Name: term_relation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE term_relation (
    term_id integer NOT NULL,
    object_type character varying(255) NOT NULL,
    object_id integer NOT NULL,
    id integer NOT NULL
);


--
-- Name: term_relation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE term_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: term_relation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE term_relation_id_seq OWNED BY term_relation.id;


--
-- Name: user_app; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE user_app (
    public_key character varying(64) NOT NULL,
    private_key character varying(128) NOT NULL,
    user_id integer NOT NULL,
    name text NOT NULL,
    status integer NOT NULL,
    create_timestamp timestamp without time zone NOT NULL
);


--
-- Name: user_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE user_meta (
    object_id integer NOT NULL,
    key character varying(128) NOT NULL,
    value text,
    id integer NOT NULL
);


--
-- Name: user_meta_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE user_meta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usr_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE usr_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: usr; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE usr (
    id integer DEFAULT nextval('usr_id_seq'::regclass) NOT NULL,
    auth_provider smallint NOT NULL,
    auth_uid character varying(512) NOT NULL,
    email character varying(255) NOT NULL,
    last_login_timestamp timestamp without time zone NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    status smallint NOT NULL,
    profile_id integer
);


--
-- Name: COLUMN usr.auth_provider; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN usr.auth_provider IS '1=openid';


--
-- Name: _mesoregiao gid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY _mesoregiao ALTER COLUMN gid SET DEFAULT nextval('_mesoregiao_gid_seq'::regclass);


--
-- Name: _microregiao gid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY _microregiao ALTER COLUMN gid SET DEFAULT nextval('_microregiao_gid_seq'::regclass);


--
-- Name: _municipios gid; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY _municipios ALTER COLUMN gid SET DEFAULT nextval('_municipios_gid_seq'::regclass);


--
-- Name: agent_meta id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent_meta ALTER COLUMN id SET DEFAULT nextval('agent_meta_id_seq'::regclass);


--
-- Name: agent_relation id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent_relation ALTER COLUMN id SET DEFAULT nextval('agent_relation_id_seq'::regclass);


--
-- Name: event id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY event ALTER COLUMN id SET DEFAULT nextval('event_id_seq'::regclass);


--
-- Name: event_meta id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_meta ALTER COLUMN id SET DEFAULT nextval('event_meta_id_seq'::regclass);


--
-- Name: event_occurrence id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence ALTER COLUMN id SET DEFAULT nextval('event_occurrence_id_seq'::regclass);


--
-- Name: event_occurrence_cancellation id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence_cancellation ALTER COLUMN id SET DEFAULT nextval('event_occurrence_cancellation_id_seq'::regclass);


--
-- Name: event_occurrence_recurrence id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence_recurrence ALTER COLUMN id SET DEFAULT nextval('event_occurrence_recurrence_id_seq'::regclass);


--
-- Name: project id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY project ALTER COLUMN id SET DEFAULT nextval('project_id_seq'::regclass);


--
-- Name: project_event id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY project_event ALTER COLUMN id SET DEFAULT nextval('project_event_id_seq'::regclass);


--
-- Name: project_meta id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY project_meta ALTER COLUMN id SET DEFAULT nextval('project_meta_id_seq'::regclass);


--
-- Name: registration_meta id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY registration_meta ALTER COLUMN id SET DEFAULT nextval('registration_meta_id_seq'::regclass);


--
-- Name: role id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY role ALTER COLUMN id SET DEFAULT nextval('role_id_seq'::regclass);


--
-- Name: space id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY space ALTER COLUMN id SET DEFAULT nextval('space_id_seq'::regclass);


--
-- Name: space_meta id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY space_meta ALTER COLUMN id SET DEFAULT nextval('space_meta_id_seq'::regclass);


--
-- Name: term id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY term ALTER COLUMN id SET DEFAULT nextval('term_id_seq'::regclass);


--
-- Name: term_relation id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY term_relation ALTER COLUMN id SET DEFAULT nextval('term_relation_id_seq'::regclass);


--
-- Data for Name: _mesoregiao; Type: TABLE DATA; Schema: public; Owner: -
--

COPY _mesoregiao (gid, id, nm_meso, cd_geocodu, geom) FROM stdin;
\.


--
-- Name: _mesoregiao_gid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('_mesoregiao_gid_seq', 1, false);


--
-- Data for Name: _microregiao; Type: TABLE DATA; Schema: public; Owner: -
--

COPY _microregiao (gid, id, nm_micro, cd_geocodu, geom) FROM stdin;
\.


--
-- Name: _microregiao_gid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('_microregiao_gid_seq', 1, false);


--
-- Data for Name: _municipios; Type: TABLE DATA; Schema: public; Owner: -
--

COPY _municipios (gid, id, cd_geocodm, nm_municip, geom) FROM stdin;
\.


--
-- Name: _municipios_gid_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('_municipios_gid_seq', 1, false);


--
-- Data for Name: agent; Type: TABLE DATA; Schema: public; Owner: -
--

COPY agent (id, parent_id, user_id, type, name, location, _geo_location, short_description, long_description, create_timestamp, status, is_verified, public_location, update_timestamp) FROM stdin;
5	\N	5	1	Staff User 1	(0,0)	0101000020E610000000000000000000000000000000000000	short description		2014-05-21 17:57:23	1	t	\N	2014-05-21 17:41:23
6	\N	6	1	Staff User 2	(0,0)	0101000020E610000000000000000000000000000000000000	short description		2014-05-21 17:57:23	1	f	\N	2014-05-21 17:42:02
1	\N	1	1	Super Admin 1	(0,0)	0101000020E610000000000000000000000000000000000000	short description		2014-05-21 17:57:23	1	t	\N	2014-05-21 17:45:03
2	\N	2	1	Super Admin 2	(0,0)	0101000020E610000000000000000000000000000000000000	short description		2014-05-21 17:57:23	1	f	\N	2014-05-21 17:38:59
3	\N	3	1	Admin 1	(-46.6451145999999994,-23.5461789999999986)	0101000020E610000008967E1D935247C011C30E63D28B37C0	short description		2014-05-21 17:57:23	1	t	f	2016-12-15 14:23:01
4	\N	4	1	Admin 2	(-46.6587759000000233,-23.5367427000000013)	0101000020E610000050F2C8C4525447C0E3DD36F8678937C0	short description		2014-05-21 17:57:23	1	f	t	2016-12-15 14:25:49
7	\N	7	1	Normal User 1	(-46.6569948999999724,-23.5335214999999991)	0101000020E6100000C091AC68185447C07E3672DD948837C0	short description		2014-05-21 17:57:23	1	t	t	2016-12-15 14:32:27
8	\N	8	1	Normal User 2	(0,0)	0101000020E610000000000000000000000000000000000000	short description		2014-05-21 17:57:23	1	f	f	2016-12-15 14:34:07
356	\N	10	1	New 1	(-46.6465663000000177,-23.5419763999999994)	0101000020E610000010993CAFC25247C02D3421F7BE8A37C0	descricao curta		2016-12-15 23:50:40	1	f	t	2016-12-15 23:51:40
357	\N	11	1	New 2	(-46.6569977999999992,-23.5338080000000005)	0101000020E6100000A0450081185447C0DA571EA4A78837C0	curta		2016-12-15 23:52:04	1	f	f	2016-12-15 23:53:17
\.


--
-- Name: agent_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('agent_id_seq', 357, true);


--
-- Data for Name: agent_meta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY agent_meta (object_id, key, value, id) FROM stdin;
3	nomeCompleto	Administrador Um	2
3	emailPublico	admin@um.com	3
3	endereco	Rua Epitácio Pessoa, 11 , República, 01220-030, São Paulo, SP	4
3	En_CEP	01220-030	5
3	En_Nome_Logradouro	Rua Epitácio Pessoa	6
3	En_Num	11	7
3	En_Bairro	República	8
3	En_Municipio	São Paulo	9
3	En_Estado	SP	10
3	sentNotification	0	1
4	nomeCompleto	Administrador Dois	11
4	endereco	Rua Doutor Brasílio Machado, 123 , Santa Cecília, 01230-010, São Paulo, SP	12
4	En_CEP	01230-010	13
4	En_Nome_Logradouro	Rua Doutor Brasílio Machado	14
4	En_Num	123	15
4	En_Bairro	Santa Cecília	16
4	En_Municipio	São Paulo	17
4	En_Estado	SP	18
7	endereco	Rua Rosa e Silva, 11 , Santa Cecília, 01230-020, São Paulo, SP	19
7	En_CEP	01230-020	20
7	En_Nome_Logradouro	Rua Rosa e Silva	21
7	En_Num	11	22
7	En_Bairro	Santa Cecília	23
7	En_Municipio	São Paulo	24
7	En_Estado	SP	25
7	nomeCompleto	Usuário Normal Um	26
8	nomeCompleto	Usuário Comum Dois	27
356	origin_site	mapas.rafa	28
356	endereco	Rua Rego Freitas, 33 , República, 01220-010, São Paulo, SP	29
356	En_CEP	01220-010	30
356	En_Nome_Logradouro	Rua Rego Freitas	31
356	En_Num	33	32
356	En_Bairro	República	33
356	En_Municipio	São Paulo	34
356	En_Estado	SP	35
357	origin_site	mapas.rafa	36
357	endereco	Rua Azevedo Marques, 32 , Santa Cecília, 01230-030, São Paulo, SP	37
357	En_CEP	01230-030	38
357	En_Nome_Logradouro	Rua Azevedo Marques	39
357	En_Num	32	40
357	En_Bairro	Santa Cecília	41
357	En_Municipio	São Paulo	42
357	En_Estado	SP	43
5	sentNotification	18	44
6	sentNotification	20	45
2	sentNotification	24	46
1	sentNotification	28	47
\.


--
-- Name: agent_meta_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('agent_meta_id_seq', 47, true);


--
-- Data for Name: agent_relation; Type: TABLE DATA; Schema: public; Owner: -
--

COPY agent_relation (id, agent_id, object_type, object_id, type, has_control, create_timestamp, status) FROM stdin;
2	3	MapasCulturais\\Entities\\Event	7	group-admin	t	2016-12-15 19:16:46	1
77	356	MapasCulturais\\Entities\\Agent	357	group-admin	t	2016-12-15 23:53:25	1
79	8	MapasCulturais\\Entities\\Event	522	group-admin	t	2016-12-15 23:57:42	-5
80	5	MapasCulturais\\Entities\\Event	522	colegas	f	2016-12-15 23:58:05	-5
78	7	MapasCulturais\\Entities\\Event	522	group-admin	t	2016-12-15 23:57:31	1
\.


--
-- Name: agent_relation_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('agent_relation_id_seq', 80, true);


--
-- Data for Name: db_update; Type: TABLE DATA; Schema: public; Owner: -
--

COPY db_update (name, exec_time) FROM stdin;
0001	2013-12-20 21:39:23.035876
remove agents and spaces with error	2014-01-29 17:06:12.622215
remove agents and spaces with error - 2014-02-07	2014-02-10 19:01:40.686626
create-occurrence_id_seq	2014-04-03 19:41:34.861338
importa programação virada cultural	2014-04-30 18:51:21.983983
importa programação virada cultural - sesc	2014-05-01 01:00:30.210001
importa programação virada cultural - estado	2014-05-02 15:29:28.296556
remove eventos e espacos antigos da virada	2014-05-07 12:47:22.131586
programação virada cultural	2014-05-07 12:48:05.991509
new random id generator	2016-12-15 11:55:01.657548
migrate gender	2016-12-15 11:55:01.657548
create table user apps	2016-12-15 11:55:01.657548
create table user_meta	2016-12-15 11:55:01.657548
create seal and seal relation tables	2016-12-15 11:55:01.657548
resize entity meta key columns	2016-12-15 11:55:01.657548
create registration field configuration table	2016-12-15 11:55:01.657548
alter table registration_file_configuration add categories	2016-12-15 11:55:01.657548
verified seal migration	2016-12-15 11:55:01.657548
create update timestamp entities	2016-12-15 11:55:01.657548
update entities last_update_timestamp with user last log timestamp	2016-12-15 11:55:01.657548
Fix field options field type from registration field configuration	2016-12-15 11:55:01.657548
Created owner seal relation field	2016-12-15 11:55:01.657548
create avatar thumbs	2016-12-15 11:55:01.657548
\.


--
-- Data for Name: event; Type: TABLE DATA; Schema: public; Owner: -
--

COPY event (id, project_id, name, short_description, long_description, rules, create_timestamp, status, agent_id, is_verified, type, update_timestamp) FROM stdin;
6	\N	Event 6	of Staff User 2		\N	2014-05-21 18:04:44	1	6	f	1	2014-05-21 17:42:02
8	\N	Event 8	of Normal User 1		\N	2014-05-21 18:04:44	1	8	f	1	2014-05-21 17:42:51
1	\N	Event 1	of Super Admin 1		\N	2014-05-21 18:04:44	1	1	t	1	2014-05-21 17:45:03
2	\N	Event 2	of Super Admin 2		\N	2014-05-21 18:04:44	1	2	f	1	2014-05-21 17:38:59
4	\N	Event 4	of Admin 2		\N	2014-05-21 18:04:44	1	4	f	1	2014-05-21 17:40:15
3	\N	Event 3	of Admin 1		\N	2014-05-21 18:04:44	1	3	t	1	2016-12-15 14:36:19
5	\N	Event 5	of Staff User 1		\N	2014-05-21 18:04:44	1	5	t	1	2016-12-15 14:39:22
7	3	Event 7	of Normal User 1		\N	2014-05-21 18:04:44	1	7	t	1	2016-12-15 19:16:37
522	\N	Novo Evento	pequeno evento		\N	2016-12-15 23:56:29	1	357	f	1	2016-12-15 23:56:33
\.


--
-- Name: event_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('event_id_seq', 522, true);


--
-- Data for Name: event_meta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY event_meta (key, object_id, value, id) FROM stdin;
classificacaoEtaria             	1	Livre	1
classificacaoEtaria             	2	Livre	2
classificacaoEtaria             	3	Livre	3
classificacaoEtaria             	4	Livre	4
classificacaoEtaria             	5	Livre	5
classificacaoEtaria             	6	Livre	6
classificacaoEtaria             	7	Livre	7
classificacaoEtaria             	8	Livre	8
classificacaoEtaria	3	Livre	9
classificacaoEtaria	5	14 anos	10
classificacaoEtaria	7	16 anos	11
classificacaoEtaria	522	Livre	12
origin_site	522	mapas.rafa	13
\.


--
-- Name: event_meta_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('event_meta_id_seq', 13, true);


--
-- Data for Name: event_occurrence; Type: TABLE DATA; Schema: public; Owner: -
--

COPY event_occurrence (id, space_id, event_id, rule, starts_on, ends_on, starts_at, ends_at, frequency, separation, count, until, timezone_name, status) FROM stdin;
142	2	3	{"spaceId":"2","startsAt":"10:00","duration":30,"endsAt":"10:30","frequency":"daily","startsOn":"2016-12-01","until":"2016-12-30","description":"Diariamente de 1 a 30 de dezembro de 2016 \\u00e0s 10:00","price":"Gratuito"}	2016-12-01	\N	2016-12-01 10:00:00	2016-12-01 10:30:00	daily	1	\N	2016-12-30	Etc/UTC	1
143	1	3	{"spaceId":"1","startsAt":"15:00","duration":120,"endsAt":"17:00","frequency":"once","startsOn":"2016-12-16","until":"","description":"Dia 16 de dezembro de 2016 \\u00e0s 15:00","price":"Gratuito"}	2016-12-16	\N	2016-12-16 15:00:00	2016-12-16 17:00:00	once	1	\N	\N	Etc/UTC	1
144	6	5	{"spaceId":"6","startsAt":"08:00","duration":5,"endsAt":"08:05","frequency":"weekly","startsOn":"2016-11-01","until":"2017-01-31","day":{"1":"on","4":"on","6":"on"},"description":"Toda seg, qui e s\\u00e1b de 1 de novembro de 2016 a 31 de janeiro de 2017 \\u00e0s 08:00","price":"R$5,00"}	2016-11-01	\N	2016-11-01 08:00:00	2016-11-01 08:05:00	weekly	1	\N	2017-01-31	Etc/UTC	1
145	4	5	{"spaceId":"4","startsAt":"09:00","duration":15,"endsAt":"09:15","frequency":"weekly","startsOn":"2016-12-01","until":"2016-12-29","day":["on","on","on","on"],"description":"Todo dom, seg, ter e qua de 1 a 29 de dezembro de 2016 \\u00e0s 09:00","price":"R$90,00"}	2016-12-01	\N	2016-12-01 09:00:00	2016-12-01 09:15:00	weekly	1	\N	2016-12-29	Etc/UTC	1
146	1	6	{"spaceId":"1","startsAt":"11:11","duration":11,"endsAt":"11:22","frequency":"once","startsOn":"2016-12-14","until":"","description":"Dia 14 de dezembro de 2016 \\u00e0s 11:11","price":"33"}	2016-12-14	\N	2016-12-14 11:11:00	2016-12-14 11:22:00	once	1	\N	\N	Etc/UTC	1
147	1	6	{"spaceId":"1","startsAt":"13:00","duration":213,"endsAt":"16:33","frequency":"once","startsOn":"2016-12-21","until":"","description":"Dia 21 de dezembro de 2016 \\u00e0s 13:00","price":"R$5,00"}	2016-12-21	\N	2016-12-21 13:00:00	2016-12-21 16:33:00	once	1	\N	\N	Etc/UTC	1
148	1	7	{"spaceId":"1","startsAt":"01:00","duration":1,"endsAt":"01:01","frequency":"once","startsOn":"2016-12-01","until":"","description":"Dia 1 de dezembro de 2016 \\u00e0 01:00","price":"33"}	2016-12-01	\N	2016-12-01 01:00:00	2016-12-01 01:01:00	once	1	\N	\N	Etc/UTC	1
149	2	7	{"spaceId":"2","startsAt":"02:00","duration":2,"endsAt":"02:02","frequency":"once","startsOn":"2016-12-02","until":"","description":"Dia 2 de dezembro de 2016 \\u00e0s 02:00","price":"12"}	2016-12-02	\N	2016-12-02 02:00:00	2016-12-02 02:02:00	once	1	\N	\N	Etc/UTC	1
150	3	7	{"spaceId":"3","startsAt":"03:00","duration":3,"endsAt":"03:03","frequency":"once","startsOn":"2016-12-03","until":"","description":"Dia 3 de dezembro de 2016 \\u00e0s 03","price":"3"}	2016-12-03	\N	2016-12-03 03:00:00	2016-12-03 03:03:00	once	1	\N	\N	Etc/UTC	1
151	4	7	{"spaceId":"4","startsAt":"04:00","duration":4,"endsAt":"04:04","frequency":"once","startsOn":"2016-12-04","until":"","description":"Dia 4 de dezembro de 2016 \\u00e0s 04:00","price":"4"}	2016-12-04	\N	2016-12-04 04:00:00	2016-12-04 04:04:00	once	1	\N	\N	Etc/UTC	1
152	5	7	{"spaceId":"5","startsAt":"05:00","duration":5,"endsAt":"05:05","frequency":"once","startsOn":"2016-12-05","until":"","description":"Dia 5 de dezembro de 2016 \\u00e0s 05:00","price":"5"}	2016-12-05	\N	2016-12-05 05:00:00	2016-12-05 05:05:00	once	1	\N	\N	Etc/UTC	1
153	6	7	{"spaceId":"6","startsAt":"06:00","duration":6,"endsAt":"06:06","frequency":"once","startsOn":"2016-12-06","until":"","description":"Dia 6 de dezembro de 2016 \\u00e0s 06:00","price":"6"}	2016-12-06	\N	2016-12-06 06:00:00	2016-12-06 06:06:00	once	1	\N	\N	Etc/UTC	1
154	7	7	{"spaceId":"7","startsAt":"07:00","duration":7,"endsAt":"07:07","frequency":"once","startsOn":"2016-12-07","until":"","description":"Dia 7 de dezembro de 2016 \\u00e0s 07:00","price":"7"}	2016-12-07	\N	2016-12-07 07:00:00	2016-12-07 07:07:00	once	1	\N	\N	Etc/UTC	1
155	8	7	{"spaceId":"8","startsAt":"08:00","duration":8,"endsAt":"08:08","frequency":"once","startsOn":"2016-12-08","until":"","description":"Dia 8 de dezembro de 2016 \\u00e0s 08:00","price":"8"}	2016-12-08	\N	2016-12-08 08:00:00	2016-12-08 08:08:00	once	1	\N	\N	Etc/UTC	1
162	1	522	{"spaceId":"1","startsAt":"11:11","duration":11,"endsAt":"11:22","frequency":"once","startsOn":"2016-12-21","until":"","description":"Dia 21 de dezembro de 2016 \\u00e0s 11:11","price":"gratuito"}	2016-12-21	\N	2016-12-21 11:11:00	2016-12-21 11:22:00	once	1	\N	\N	Etc/UTC	-5
163	2	522	{"spaceId":"2","startsAt":"22:22","duration":22,"endsAt":"22:44","frequency":"once","startsOn":"2016-12-30","until":"","description":"Dia 30 de dezembro de 2016 \\u00e0s 22:22","price":"R$ 1,00"}	2016-12-30	\N	2016-12-30 22:22:00	2016-12-30 22:44:00	once	1	\N	\N	Etc/UTC	1
\.


--
-- Data for Name: event_occurrence_cancellation; Type: TABLE DATA; Schema: public; Owner: -
--

COPY event_occurrence_cancellation (id, event_occurrence_id, date) FROM stdin;
\.


--
-- Name: event_occurrence_cancellation_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('event_occurrence_cancellation_id_seq', 1, true);


--
-- Name: event_occurrence_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('event_occurrence_id_seq', 163, true);


--
-- Data for Name: event_occurrence_recurrence; Type: TABLE DATA; Schema: public; Owner: -
--

COPY event_occurrence_recurrence (id, event_occurrence_id, month, day, week) FROM stdin;
107	144	\N	1	\N
108	144	\N	4	\N
109	144	\N	6	\N
110	145	\N	0	\N
111	145	\N	1	\N
112	145	\N	2	\N
113	145	\N	3	\N
\.


--
-- Name: event_occurrence_recurrence_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('event_occurrence_recurrence_id_seq', 116, true);


--
-- Data for Name: file; Type: TABLE DATA; Schema: public; Owner: -
--

COPY file (id, md5, mime_type, name, object_type, object_id, create_timestamp, grp, description, parent_id) FROM stdin;
2	3f33b6a80a91f393ac2b023b5511d373	image/jpeg	imagem4.jpeg	MapasCulturais\\Entities\\Space	2	2016-12-15 14:12:31	avatar	\N	\N
3	41d23133056bf227bae7ab1c89c863df	image/jpeg	imagem4-4e0f09ec602df7f0dbe0ffa44c19eb5e.jpeg	MapasCulturais\\Entities\\Space	2	2016-12-15 14:12:31	img:avatarSmall	\N	2
4	5dc784743746f51597fc5aca8d6fb5b7	image/jpeg	imagem4-570b654c331f46e4d3f3128fc55722d3.jpeg	MapasCulturais\\Entities\\Space	2	2016-12-15 14:12:31	img:avatarMedium	\N	2
5	35bbe33b02e7e12beaea44ccb51ed97e	image/jpeg	imagem4-792da4142aad216c71edf68c0c3387ef.jpeg	MapasCulturais\\Entities\\Space	2	2016-12-15 14:12:31	img:avatarBig	\N	2
6	a6c571bb166e02a180208234d202708f	image/jpeg	imagem1.jpeg	MapasCulturais\\Entities\\Space	4	2016-12-15 14:12:45	avatar	\N	\N
7	0a94172721b6d02d216888d21c00e108	image/jpeg	imagem1-0108e4d03baa58da37295fac2878acaf.jpeg	MapasCulturais\\Entities\\Space	4	2016-12-15 14:12:45	img:avatarSmall	\N	6
8	2f630aa1bba07be1ad4abd9bd9cb460b	image/jpeg	imagem1-edddfc71895c873e781944d65e9fc3e0.jpeg	MapasCulturais\\Entities\\Space	4	2016-12-15 14:12:45	img:avatarMedium	\N	6
9	c0c83d612112a51fdda383127a5e00ea	image/jpeg	imagem1-7a9bc5ba8184c729ca3ce9c850ee90b5.jpeg	MapasCulturais\\Entities\\Space	4	2016-12-15 14:12:45	img:avatarBig	\N	6
10	c380de3fb7ac84320357c6b0852d37d6	image/jpeg	imagem3.jpeg	MapasCulturais\\Entities\\Space	6	2016-12-15 14:18:24	avatar	\N	\N
11	e472306e5ae360b8f2880966fbeb1180	image/jpeg	imagem3-ed0f3136f28c0cbcea89572e0bf16825.jpeg	MapasCulturais\\Entities\\Space	6	2016-12-15 14:18:24	img:avatarSmall	\N	10
12	2256bbbfb2595ec8d78ae4a9e22ba0d4	image/jpeg	imagem3-8e0c7f12f218eec531833cebb8deee4e.jpeg	MapasCulturais\\Entities\\Space	6	2016-12-15 14:18:24	img:avatarMedium	\N	10
13	c2c0986bbba641695972c9ca67eace56	image/jpeg	imagem3-1d54b3eea7eeb5139f95fbb00f0a0498.jpeg	MapasCulturais\\Entities\\Space	6	2016-12-15 14:18:24	img:avatarBig	\N	10
14	02c3557636e47601e2c3bf97a1aacd34	image/jpeg	imagem2.jpeg	MapasCulturais\\Entities\\Space	1	2016-12-15 14:19:52	avatar	\N	\N
15	1eb521a246d2dfc7e2efc5e502643915	image/jpeg	imagem2-1d80d1d4d8de1e61294630edb215f103.jpeg	MapasCulturais\\Entities\\Space	1	2016-12-15 14:19:52	img:avatarSmall	\N	14
16	c0d2bbe7a87f902e5889c6920dcb657f	image/jpeg	imagem2-6086f8a4969eda83f4fe75a5bd40603d.jpeg	MapasCulturais\\Entities\\Space	1	2016-12-15 14:19:52	img:avatarMedium	\N	14
17	9e12dc99411445974b4c9776bf262662	image/jpeg	imagem2-742ae267c66f6f4df1a34a11ebb3c618.jpeg	MapasCulturais\\Entities\\Space	1	2016-12-15 14:19:52	img:avatarBig	\N	14
18	a6c571bb166e02a180208234d202708f	image/jpeg	imagem1.jpeg	MapasCulturais\\Entities\\Agent	3	2016-12-15 14:22:05	avatar	\N	\N
19	0a94172721b6d02d216888d21c00e108	image/jpeg	imagem1-0108e4d03baa58da37295fac2878acaf.jpeg	MapasCulturais\\Entities\\Agent	3	2016-12-15 14:22:05	img:avatarSmall	\N	18
20	2f630aa1bba07be1ad4abd9bd9cb460b	image/jpeg	imagem1-edddfc71895c873e781944d65e9fc3e0.jpeg	MapasCulturais\\Entities\\Agent	3	2016-12-15 14:22:05	img:avatarMedium	\N	18
21	c0c83d612112a51fdda383127a5e00ea	image/jpeg	imagem1-7a9bc5ba8184c729ca3ce9c850ee90b5.jpeg	MapasCulturais\\Entities\\Agent	3	2016-12-15 14:22:05	img:avatarBig	\N	18
22	02c3557636e47601e2c3bf97a1aacd34	image/jpeg	imagem2.jpeg	MapasCulturais\\Entities\\Agent	4	2016-12-15 14:24:36	avatar	\N	\N
23	1eb521a246d2dfc7e2efc5e502643915	image/jpeg	imagem2-1d80d1d4d8de1e61294630edb215f103.jpeg	MapasCulturais\\Entities\\Agent	4	2016-12-15 14:24:36	img:avatarSmall	\N	22
24	c0d2bbe7a87f902e5889c6920dcb657f	image/jpeg	imagem2-6086f8a4969eda83f4fe75a5bd40603d.jpeg	MapasCulturais\\Entities\\Agent	4	2016-12-15 14:24:36	img:avatarMedium	\N	22
25	9e12dc99411445974b4c9776bf262662	image/jpeg	imagem2-742ae267c66f6f4df1a34a11ebb3c618.jpeg	MapasCulturais\\Entities\\Agent	4	2016-12-15 14:24:36	img:avatarBig	\N	22
26	3f33b6a80a91f393ac2b023b5511d373	image/jpeg	imagem4.jpeg	MapasCulturais\\Entities\\Agent	7	2016-12-15 14:33:03	avatar	\N	\N
27	41d23133056bf227bae7ab1c89c863df	image/jpeg	imagem4-4e0f09ec602df7f0dbe0ffa44c19eb5e.jpeg	MapasCulturais\\Entities\\Agent	7	2016-12-15 14:33:03	img:avatarSmall	\N	26
28	5dc784743746f51597fc5aca8d6fb5b7	image/jpeg	imagem4-570b654c331f46e4d3f3128fc55722d3.jpeg	MapasCulturais\\Entities\\Agent	7	2016-12-15 14:33:03	img:avatarMedium	\N	26
29	35bbe33b02e7e12beaea44ccb51ed97e	image/jpeg	imagem4-792da4142aad216c71edf68c0c3387ef.jpeg	MapasCulturais\\Entities\\Agent	7	2016-12-15 14:33:03	img:avatarBig	\N	26
30	c380de3fb7ac84320357c6b0852d37d6	image/jpeg	imagem3.jpeg	MapasCulturais\\Entities\\Agent	8	2016-12-15 14:33:48	avatar	\N	\N
31	e472306e5ae360b8f2880966fbeb1180	image/jpeg	imagem3-ed0f3136f28c0cbcea89572e0bf16825.jpeg	MapasCulturais\\Entities\\Agent	8	2016-12-15 14:33:48	img:avatarSmall	\N	30
32	2256bbbfb2595ec8d78ae4a9e22ba0d4	image/jpeg	imagem3-8e0c7f12f218eec531833cebb8deee4e.jpeg	MapasCulturais\\Entities\\Agent	8	2016-12-15 14:33:48	img:avatarMedium	\N	30
33	c2c0986bbba641695972c9ca67eace56	image/jpeg	imagem3-1d54b3eea7eeb5139f95fbb00f0a0498.jpeg	MapasCulturais\\Entities\\Agent	8	2016-12-15 14:33:48	img:avatarBig	\N	30
34	a6c571bb166e02a180208234d202708f	image/jpeg	imagem1.jpeg	MapasCulturais\\Entities\\Event	5	2016-12-15 14:37:19	avatar	\N	\N
35	0a94172721b6d02d216888d21c00e108	image/jpeg	imagem1-0108e4d03baa58da37295fac2878acaf.jpeg	MapasCulturais\\Entities\\Event	5	2016-12-15 14:37:19	img:avatarSmall	\N	34
36	2f630aa1bba07be1ad4abd9bd9cb460b	image/jpeg	imagem1-edddfc71895c873e781944d65e9fc3e0.jpeg	MapasCulturais\\Entities\\Event	5	2016-12-15 14:37:19	img:avatarMedium	\N	34
37	c0c83d612112a51fdda383127a5e00ea	image/jpeg	imagem1-7a9bc5ba8184c729ca3ce9c850ee90b5.jpeg	MapasCulturais\\Entities\\Event	5	2016-12-15 14:37:19	img:avatarBig	\N	34
38	c380de3fb7ac84320357c6b0852d37d6	image/jpeg	imagem3.jpeg	MapasCulturais\\Entities\\Event	6	2016-12-15 14:39:58	avatar	\N	\N
39	e472306e5ae360b8f2880966fbeb1180	image/jpeg	imagem3-ed0f3136f28c0cbcea89572e0bf16825.jpeg	MapasCulturais\\Entities\\Event	6	2016-12-15 14:39:58	img:avatarSmall	\N	38
40	2256bbbfb2595ec8d78ae4a9e22ba0d4	image/jpeg	imagem3-8e0c7f12f218eec531833cebb8deee4e.jpeg	MapasCulturais\\Entities\\Event	6	2016-12-15 14:39:58	img:avatarMedium	\N	38
41	c2c0986bbba641695972c9ca67eace56	image/jpeg	imagem3-1d54b3eea7eeb5139f95fbb00f0a0498.jpeg	MapasCulturais\\Entities\\Event	6	2016-12-15 14:39:58	img:avatarBig	\N	38
42	02c3557636e47601e2c3bf97a1aacd34	image/jpeg	imagem2.jpeg	MapasCulturais\\Entities\\Event	7	2016-12-15 14:42:32	avatar	\N	\N
43	1eb521a246d2dfc7e2efc5e502643915	image/jpeg	imagem2-1d80d1d4d8de1e61294630edb215f103.jpeg	MapasCulturais\\Entities\\Event	7	2016-12-15 14:42:32	img:avatarSmall	\N	42
44	c0d2bbe7a87f902e5889c6920dcb657f	image/jpeg	imagem2-6086f8a4969eda83f4fe75a5bd40603d.jpeg	MapasCulturais\\Entities\\Event	7	2016-12-15 14:42:32	img:avatarMedium	\N	42
45	9e12dc99411445974b4c9776bf262662	image/jpeg	imagem2-742ae267c66f6f4df1a34a11ebb3c618.jpeg	MapasCulturais\\Entities\\Event	7	2016-12-15 14:42:32	img:avatarBig	\N	42
46	10305e262127a496bdf7fceefa0ec85f	image/jpeg	imagem1-220f3fdda72e0ff473c8d3488d0fec7d.jpeg	MapasCulturais\\Entities\\Event	5	2016-12-15 14:54:48	img:galleryFull	\N	34
\.


--
-- Name: file_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('file_id_seq', 74, true);


--
-- Data for Name: geo_division; Type: TABLE DATA; Schema: public; Owner: -
--

COPY geo_division (id, parent_id, type, cod, name, geom) FROM stdin;
\.


--
-- Name: geo_division_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('geo_division_id_seq', 1, false);


--
-- Data for Name: metadata; Type: TABLE DATA; Schema: public; Owner: -
--

COPY metadata (object_id, object_type, key, value) FROM stdin;
\.


--
-- Data for Name: metalist; Type: TABLE DATA; Schema: public; Owner: -
--

COPY metalist (id, object_type, object_id, grp, title, description, value, create_timestamp, "order") FROM stdin;
\.


--
-- Name: metalist_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('metalist_id_seq', 1, true);


--
-- Data for Name: notification; Type: TABLE DATA; Schema: public; Owner: -
--

COPY notification (id, user_id, request_id, message, create_timestamp, action_timestamp, status) FROM stdin;
1	3	\N	Seu último acesso foi em <b>21/05/2014</b>, atualize suas informações se necessário.	2016-12-15 11:57:24	\N	1
4	7	\N	Seu último acesso foi em <b>21/05/2014</b>, atualize suas informações se necessário.	2016-12-15 22:24:28	\N	1
7	11	\N	<a href="http://localhost:8888/agente/356/">New 1</a> aceitou o relacionamento do agente <a href="http://localhost:8888/agente/356/">New 1</a> com o agente <a href="http://localhost:8888/agente/357/">New 2</a>.	2016-12-15 23:53:41	\N	1
8	11	18	Sua requisição para criar a ocorrência do evento <a href="http://localhost:8888/evento/522/">Novo Evento</a> no espaço <a href="http://localhost:8888/espaco/1/">Space 1</a> foi enviada.	2016-12-15 23:57:14	\N	1
9	1	18	<a href="http://localhost:8888/agente/357/">New 2</a> quer adicionar o evento <a href="http://localhost:8888/evento/522/">Novo Evento</a> que ocorre <em>Dia 21 de dezembro de 2016 às 11:11</em> no espaço <a href="http://localhost:8888/espaco/1/">Space 1</a>.	2016-12-15 23:57:14	\N	1
12	11	20	Sua requisição para relacionar o agente <a href="http://localhost:8888/agente/8/">Normal User 2</a> ao evento <a href="http://localhost:8888/evento/522/">Novo Evento</a> foi enviada.	2016-12-15 23:57:42	\N	1
13	8	20	<a href="http://localhost:8888/agente/357/">New 2</a> quer relacionar o agente <a href="http://localhost:8888/agente/8/">Normal User 2</a> ao evento <a href="http://localhost:8888/evento/522/">Novo Evento</a>.	2016-12-15 23:57:42	\N	1
14	11	21	Sua requisição para relacionar o agente <a href="http://localhost:8888/agente/5/">Staff User 1</a> ao evento <a href="http://localhost:8888/evento/522/">Novo Evento</a> foi enviada.	2016-12-15 23:58:05	\N	1
15	5	21	<a href="http://localhost:8888/agente/357/">New 2</a> quer relacionar o agente <a href="http://localhost:8888/agente/5/">Staff User 1</a> ao evento <a href="http://localhost:8888/evento/522/">Novo Evento</a>.	2016-12-15 23:58:05	\N	1
16	11	\N	<a href="http://localhost:8888/agente/7/">Normal User 1</a> aceitou o relacionamento do agente <a href="http://localhost:8888/agente/7/">Normal User 1</a> com o evento <a href="http://localhost:8888/evento/522/">Novo Evento</a>.	2016-12-15 23:59:50	\N	1
17	5	\N	Seu último acesso foi em <b>21/05/2014</b>, atualize suas informações se necessário.	2016-12-15 23:59:59	\N	1
18	5	\N	O agente <b>Staff User 1</b> não é atualizado desde de <b>21/05/2014</b>, atualize as informações se necessário.<a class="btn btn-small btn-primary" href="http://localhost:8888/agentes/edita/5/">editar</a>	2016-12-15 23:59:59	\N	1
19	6	\N	Seu último acesso foi em <b>21/05/2014</b>, atualize suas informações se necessário.	2016-12-16 00:00:15	\N	1
20	6	\N	O agente <b>Staff User 2</b> não é atualizado desde de <b>21/05/2014</b>, atualize as informações se necessário.<a class="btn btn-small btn-primary" href="http://localhost:8888/agentes/edita/6/">editar</a>	2016-12-16 00:00:15	\N	1
23	2	\N	Seu último acesso foi em <b>21/05/2014</b>, atualize suas informações se necessário.	2016-12-16 00:01:45	\N	1
24	2	\N	O agente <b>Super Admin 2</b> não é atualizado desde de <b>21/05/2014</b>, atualize as informações se necessário.<a class="btn btn-small btn-primary" href="http://localhost:8888/agentes/edita/2/">editar</a>	2016-12-16 00:01:45	\N	1
25	11	\N	<a href="http://localhost:8888/agente/2/">Super Admin 2</a> aceitou adicionar o evento <a href="http://localhost:8888/evento/522/">Novo Evento</a> que ocorre <em>Dia 30 de dezembro de 2016 às 22:22</em> no espaço <a href="http://localhost:8888/espaco/2/">Space 2</a>.	2016-12-16 00:02:14	\N	1
26	4	\N	Seu último acesso foi em <b>21/05/2014</b>, atualize suas informações se necessário.	2016-12-16 00:07:54	\N	1
27	1	\N	Seu último acesso foi em <b>21/05/2014</b>, atualize suas informações se necessário.	2016-12-16 00:17:56	\N	1
28	1	\N	O agente <b>Super Admin 1</b> não é atualizado desde de <b>21/05/2014</b>, atualize as informações se necessário.<a class="btn btn-small btn-primary" href="http://localhost:8888/agentes/edita/1/">editar</a>	2016-12-16 00:17:56	\N	1
29	8	\N	Seu último acesso foi em <b>21/05/2014</b>, atualize suas informações se necessário.	2016-12-16 00:19:59	\N	1
\.


--
-- Name: notification_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('notification_id_seq', 29, true);


--
-- Name: occurrence_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('occurrence_id_seq', 100000, false);


--
-- Data for Name: project; Type: TABLE DATA; Schema: public; Owner: -
--

COPY project (id, name, short_description, long_description, create_timestamp, status, agent_id, is_verified, type, parent_id, registration_from, registration_to, registration_categories, use_registrations, published_registrations, update_timestamp) FROM stdin;
5	Project 5	of Staff User 1	\N	2014-05-21 18:04:41	1	5	t	1	\N	\N	\N	\N	f	f	2014-05-21 17:41:23
6	Project 6	of Staff User 2	\N	2014-05-21 18:04:41	1	6	f	1	\N	\N	\N	\N	f	t	2014-05-21 17:42:02
7	Project 7	of Normal User 1	\N	2014-05-21 18:04:41	1	7	t	1	\N	\N	\N	\N	f	f	2014-05-21 17:42:35
8	Project 8	of Normal User 1	\N	2014-05-21 18:04:41	1	8	f	1	\N	\N	\N	\N	f	t	2014-05-21 17:42:51
1	Project 1	of Super Admin 1	\N	2014-05-21 18:04:41	1	1	t	1	\N	\N	\N	\N	f	t	2014-05-21 17:45:03
2	Project 2	of Super Admin 2	\N	2014-05-21 18:04:41	1	2	f	1	\N	\N	\N	\N	f	t	2014-05-21 17:38:59
3	Project 3	of Admin 1	\N	2014-05-21 18:04:41	1	3	t	1	\N	\N	\N	\N	f	f	2014-05-21 17:39:34
4	Project 4	of Admin 2	\N	2014-05-21 18:04:41	1	4	f	1	\N	\N	\N	\N	f	f	2014-05-21 17:40:15
\.


--
-- Data for Name: project_event; Type: TABLE DATA; Schema: public; Owner: -
--

COPY project_event (id, event_id, project_id, type, status) FROM stdin;
\.


--
-- Name: project_event_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('project_event_id_seq', 1, true);


--
-- Name: project_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('project_id_seq', 345, true);


--
-- Data for Name: project_meta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY project_meta (object_id, key, value, id) FROM stdin;
\.


--
-- Name: project_meta_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('project_meta_id_seq', 1, false);


--
-- Name: pseudo_random_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('pseudo_random_id_seq', 1, false);


--
-- Data for Name: registration; Type: TABLE DATA; Schema: public; Owner: -
--

COPY registration (id, project_id, category, agent_id, create_timestamp, sent_timestamp, status, agents_data) FROM stdin;
\.


--
-- Data for Name: registration_field_configuration; Type: TABLE DATA; Schema: public; Owner: -
--

COPY registration_field_configuration (id, project_id, title, description, categories, required, field_type, field_options) FROM stdin;
\.


--
-- Name: registration_field_configuration_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('registration_field_configuration_id_seq', 1, false);


--
-- Data for Name: registration_file_configuration; Type: TABLE DATA; Schema: public; Owner: -
--

COPY registration_file_configuration (id, project_id, title, description, required, categories) FROM stdin;
\.


--
-- Name: registration_file_configuration_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('registration_file_configuration_id_seq', 1, false);


--
-- Name: registration_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('registration_id_seq', 1, false);


--
-- Data for Name: registration_meta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY registration_meta (object_id, key, value, id) FROM stdin;
\.


--
-- Name: registration_meta_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('registration_meta_id_seq', 1, false);


--
-- Data for Name: request; Type: TABLE DATA; Schema: public; Owner: -
--

COPY request (id, request_uid, requester_user_id, origin_type, origin_id, destination_type, destination_id, metadata, type, create_timestamp, action_timestamp, status) FROM stdin;
18	3564e6b660d177cebb1ebb521d035978	11	MapasCulturais\\Entities\\Event	522	MapasCulturais\\Entities\\Space	1	a:2:{s:19:"event_occurrence_id";i:162;s:4:"rule";O:8:"stdClass":9:{s:7:"spaceId";s:1:"1";s:8:"startsAt";s:5:"11:11";s:8:"duration";i:11;s:6:"endsAt";s:5:"11:22";s:9:"frequency";s:4:"once";s:8:"startsOn";s:10:"2016-12-21";s:5:"until";s:0:"";s:11:"description";s:36:"Dia 21 de dezembro de 2016 às 11:11";s:5:"price";s:8:"gratuito";}}	EventOccurrence	2016-12-15 23:57:14	\N	1
20	1045c299290c5bb7b697ea313043d839	11	MapasCulturais\\Entities\\Event	522	MapasCulturais\\Entities\\Agent	8	a:2:{s:5:"class";s:42:"MapasCulturais\\Entities\\EventAgentRelation";s:10:"relationId";i:79;}	AgentRelation	2016-12-15 23:57:42	\N	1
21	add514f40efa7d3d4e98c490cbd2c59c	11	MapasCulturais\\Entities\\Event	522	MapasCulturais\\Entities\\Agent	5	a:2:{s:5:"class";s:42:"MapasCulturais\\Entities\\EventAgentRelation";s:10:"relationId";i:80;}	AgentRelation	2016-12-15 23:58:05	\N	1
\.


--
-- Name: request_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('request_id_seq', 22, true);


--
-- Data for Name: role; Type: TABLE DATA; Schema: public; Owner: -
--

COPY role (id, usr_id, name) FROM stdin;
1	1	superAdmin
3	3	admin
4	4	admin
5	5	staff
6	6	staff
2	2	superAdmin
\.


--
-- Name: role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('role_id_seq', 127, true);


--
-- Data for Name: seal; Type: TABLE DATA; Schema: public; Owner: -
--

COPY seal (id, agent_id, name, short_description, long_description, valid_period, create_timestamp, status, certificate_text, update_timestamp) FROM stdin;
1	1	Selo Mapas	Descrição curta Selo Mapas	Descrição longa Selo Mapas	0	2016-12-15 11:55:02	1	\N	2014-05-21 17:45:03
\.


--
-- Name: seal_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('seal_id_seq', 1, false);


--
-- Data for Name: seal_meta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY seal_meta (id, object_id, key, value) FROM stdin;
\.


--
-- Name: seal_meta_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('seal_meta_id_seq', 1, false);


--
-- Data for Name: seal_relation; Type: TABLE DATA; Schema: public; Owner: -
--

COPY seal_relation (id, seal_id, object_id, create_timestamp, status, object_type, agent_id, owner_id) FROM stdin;
1	1	5	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Agent	1	1
2	1	7	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Agent	1	1
3	1	1	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Agent	1	1
4	1	3	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Agent	1	1
5	1	1	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Space	1	1
6	1	7	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Space	1	1
7	1	5	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Space	1	1
8	1	3	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Space	1	1
9	1	1	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Project	1	1
10	1	3	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Project	1	1
11	1	5	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Project	1	1
12	1	7	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Project	1	1
13	1	1	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Event	1	1
14	1	3	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Event	1	1
15	1	5	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Event	1	1
16	1	7	2016-12-15 11:55:02	1	MapasCulturais\\Entities\\Event	1	1
\.


--
-- Name: seal_relation_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('seal_relation_id_seq', 16, true);


--
-- Data for Name: space; Type: TABLE DATA; Schema: public; Owner: -
--

COPY space (id, parent_id, location, _geo_location, name, short_description, long_description, create_timestamp, status, type, agent_id, is_verified, public, update_timestamp) FROM stdin;
7	\N	(-46.6915816000000063,-23.5394311999999992)	0101000020E6100000F841F1BE855847C02971C229188A37C0	Space 7	of Normal User 1		2014-05-21 18:04:38	1	20	7	t	f	2016-12-15 13:22:04
8	\N	(-46.6468626999999856,-23.5466151000000004)	0101000020E610000048C09E65CC5247C0F1FF99F7EE8B37C0	Space 8	of Normal User 1		2014-05-21 18:04:38	1	22	8	f	f	2016-12-15 13:22:16
6	\N	(-48.5070640999999796,-27.5887011999999991)	0101000020E6100000E03CF779E74048C0AF1D311FB5963BC0	Space 6	of Staff User 2		2014-05-21 18:04:38	1	61	6	f	f	2016-12-15 13:22:47
5	\N	(-48.5102924000000257,-27.5666994999999986)	0101000020E6100000E0B2E842514148C0D828EB3713913BC0	Space 5	of Staff User 1		2014-05-21 18:04:38	1	91	5	t	f	2016-12-15 13:24:17
4	\N	(-46.6499110999999971,-23.5575986999999998)	0101000020E610000058E77349305347C0C8CAD4C9BE8E37C0	Space 4	of Admin 2		2014-05-21 18:04:38	1	60	4	f	f	2016-12-15 13:27:44
3	\N	(-46.6343521999999666,-23.5299146000000015)	0101000020E6100000A092F073325147C045ACB47BA88737C0	Space 3	of Admin 1		2014-05-21 18:04:38	1	10	3	t	f	2016-12-15 13:51:45
2	\N	(-48.5129766000000018,-27.5906075000000008)	0101000020E6100000804E9C37A94148C0B745990D32973BC0	Space 2	of Super Admin 2		2014-05-21 18:04:38	1	10	2	f	f	2016-12-15 13:53:47
1	\N	(-46.6444261999999981,-23.5443493000000004)	0101000020E6100000C0D7C68E7C5247C0BA19C9795A8B37C0	Space 1	of Super Admin 1		2014-05-21 18:04:38	1	10	1	t	f	2016-12-15 14:20:58
\.


--
-- Name: space_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('space_id_seq', 491, true);


--
-- Data for Name: space_meta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY space_meta (object_id, key, value, id) FROM stdin;
8	acessibilidade	Sim	2
6	acessibilidade	Sim	3
8	endereco	Rua Rego Freitas, 530 , República, 01220-010, São Paulo, SP	4
8	En_CEP	01220-010	5
8	En_Nome_Logradouro	Rua Rego Freitas	6
8	En_Num	530	7
8	En_Bairro	República	8
8	En_Municipio	São Paulo	9
8	En_Estado	SP	10
8	acessibilidade_fisica	Elevador;Rampa de acesso	11
7	acessibilidade	Não	12
7	endereco	Rua Engenheiro Francisco Azevedo, 216 , Jardim Vera Cruz, 05030-010, São Paulo, SP	13
7	En_CEP	05030-010	14
7	En_Nome_Logradouro	Rua Engenheiro Francisco Azevedo	15
7	En_Num	216	16
7	En_Bairro	Jardim Vera Cruz	17
7	En_Municipio	São Paulo	18
7	En_Estado	SP	19
6	En_CEP	88035-001	20
6	En_Bairro	Santa Mônica	24
6	En_Municipio	Florianópolis	25
6	En_Estado	SC	26
6	endereco	Avenida Madre Benvenuta, 1498 , Santa Mônica, 88035-001, Florianópolis, SC	21
6	En_Nome_Logradouro	Avenida Madre Benvenuta	22
6	En_Num	1498	23
6	acessibilidade_fisica	Rampa de acesso	27
5	endereco	Rodovia José Carlos Daux, 32 , João Paulo, 88030-000, Florianópolis, SC	28
5	En_CEP	88030-000	29
5	En_Nome_Logradouro	Rodovia José Carlos Daux	30
5	En_Num	32	31
5	En_Bairro	João Paulo	32
5	En_Municipio	Florianópolis	33
5	En_Estado	SC	34
5	acessibilidade	Não	35
4	acessibilidade	Sim	36
4	acessibilidade_fisica	Sinalização tátil;Rampa de acesso;Vaga de estacionamento exclusiva para idosos;Elevador	37
4	endereco	Rua Itapeva, 15 , Bela Vista, 01332-000, São Paulo, SP	38
4	En_CEP	01332-000	39
4	En_Nome_Logradouro	Rua Itapeva	40
4	En_Num	15	41
4	En_Bairro	Bela Vista	42
4	En_Municipio	São Paulo	43
4	En_Estado	SP	44
3	acessibilidade	Sim	45
3	acessibilidade_fisica	Elevador	46
3	endereco	Rua Três Rios, 20 , Bom Retiro, 01123-000, São Paulo, SP	47
3	En_CEP	01123-000	48
3	En_Nome_Logradouro	Rua Três Rios	49
3	En_Num	20	50
3	En_Bairro	Bom Retiro	51
3	En_Municipio	São Paulo	52
3	En_Estado	SP	53
3	sentNotification	0	1
2	endereco	Rua Tenente Jerônimo Borges, 33 , Santa Mônica, 88035-050, Florianópolis, SC	54
2	En_CEP	88035-050	55
2	En_Nome_Logradouro	Rua Tenente Jerônimo Borges	56
2	En_Num	33	57
2	En_Bairro	Santa Mônica	58
2	En_Municipio	Florianópolis	59
2	En_Estado	SC	60
2	acessibilidade	Não	61
2	acessibilidade_fisica	Estacionamento	62
1	endereco	Rua Araújo, 22 , República, 01220-020, São Paulo, SP	63
1	En_CEP	01220-020	64
1	En_Nome_Logradouro	Rua Araújo	65
1	En_Num	22	66
1	En_Bairro	República	67
1	En_Municipio	São Paulo	68
1	En_Estado	SP	69
\.


--
-- Name: space_meta_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('space_meta_id_seq', 69, true);


--
-- Data for Name: spatial_ref_sys; Type: TABLE DATA; Schema: public; Owner: -
--

COPY spatial_ref_sys (srid, auth_name, auth_srid, srtext, proj4text) FROM stdin;
\.


--
-- Data for Name: term; Type: TABLE DATA; Schema: public; Owner: -
--

COPY term (id, taxonomy, term, description) FROM stdin;
2	2	Antropologia	DESCRIÇÃO
3	2	Arqueologia	DESCRIÇÃO
4	2	Arquitetura-Urbanismo	DESCRIÇÃO
5	2	Arquivo	DESCRIÇÃO
6	2	Artesanato	DESCRIÇÃO
7	2	Artes Visuais	DESCRIÇÃO
8	2	Cultura Negra	DESCRIÇÃO
9	2	Fotografia	DESCRIÇÃO
10	2	Jogos Eletrônicos	DESCRIÇÃO
11	2	Circo	DESCRIÇÃO
12	2	Filosofia	DESCRIÇÃO
13	2	Música	
14	2	Arte Digital	
15	2	Arte de Rua	
16	2	Esporte	
17	2	Cinema	
18	3	Cinema	
19	3	Música Popular	
20	3	Cultura Indígena	
21	3	Rádio	
42	1	TAGUEADO	
43	3	Artes Circenses	
\.


--
-- Name: term_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('term_id_seq', 43, true);


--
-- Data for Name: term_relation; Type: TABLE DATA; Schema: public; Owner: -
--

COPY term_relation (term_id, object_type, object_id, id) FROM stdin;
2	MapasCulturais\\Entities\\Agent	1	1
3	MapasCulturais\\Entities\\Agent	2	2
4	MapasCulturais\\Entities\\Agent	3	3
5	MapasCulturais\\Entities\\Agent	4	4
6	MapasCulturais\\Entities\\Agent	5	5
7	MapasCulturais\\Entities\\Agent	6	6
5	MapasCulturais\\Entities\\Agent	7	7
4	MapasCulturais\\Entities\\Agent	8	8
2	MapasCulturais\\Entities\\Space	8	9
4	MapasCulturais\\Entities\\Space	7	10
6	MapasCulturais\\Entities\\Space	6	11
8	MapasCulturais\\Entities\\Space	5	12
9	MapasCulturais\\Entities\\Space	4	13
10	MapasCulturais\\Entities\\Space	3	14
11	MapasCulturais\\Entities\\Space	2	15
12	MapasCulturais\\Entities\\Space	1	16
6	MapasCulturais\\Entities\\Space	7	17
13	MapasCulturais\\Entities\\Space	8	18
14	MapasCulturais\\Entities\\Space	6	19
11	MapasCulturais\\Entities\\Space	5	20
13	MapasCulturais\\Entities\\Space	5	21
14	MapasCulturais\\Entities\\Space	4	22
7	MapasCulturais\\Entities\\Space	4	23
14	MapasCulturais\\Entities\\Space	3	24
15	MapasCulturais\\Entities\\Space	2	25
16	MapasCulturais\\Entities\\Space	1	26
10	MapasCulturais\\Entities\\Space	1	27
15	MapasCulturais\\Entities\\Agent	7	28
17	MapasCulturais\\Entities\\Agent	7	29
18	MapasCulturais\\Entities\\Event	3	30
19	MapasCulturais\\Entities\\Event	5	31
20	MapasCulturais\\Entities\\Event	7	32
21	MapasCulturais\\Entities\\Event	7	33
14	MapasCulturais\\Entities\\Agent	356	56
42	MapasCulturais\\Entities\\Agent	356	57
15	MapasCulturais\\Entities\\Agent	357	58
42	MapasCulturais\\Entities\\Agent	357	59
18	MapasCulturais\\Entities\\Event	522	60
43	MapasCulturais\\Entities\\Event	522	61
\.


--
-- Name: term_relation_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('term_relation_id_seq', 61, true);


--
-- Data for Name: user_app; Type: TABLE DATA; Schema: public; Owner: -
--

COPY user_app (public_key, private_key, user_id, name, status, create_timestamp) FROM stdin;
\.


--
-- Data for Name: user_meta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY user_meta (object_id, key, value, id) FROM stdin;
\.


--
-- Name: user_meta_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('user_meta_id_seq', 1, false);


--
-- Data for Name: usr; Type: TABLE DATA; Schema: public; Owner: -
--

COPY usr (id, auth_provider, auth_uid, email, last_login_timestamp, create_timestamp, status, profile_id) FROM stdin;
5	1	1	Staff1@local	2016-12-15 23:59:59	2014-05-21 17:41:23	1	5
6	1	1	Staff2@local	2016-12-16 00:00:15	2014-05-21 17:42:02	1	6
2	1	1	SuperAdmin2@local	2016-12-16 00:01:45	2014-05-21 17:38:59	1	2
3	1	1	Admin1@local	2016-12-16 00:04:14	2014-05-21 17:39:34	1	3
4	1	1	Admin2@local	2016-12-16 00:07:54	2014-05-21 17:40:15	1	4
7	1	1	Normal1@local	2016-12-16 00:15:48	2014-05-21 17:42:35	1	7
1	1	1	SuperAdmin1@local	2016-12-16 00:17:56	2014-05-21 17:45:03	1	1
8	1	1	Normal2@local	2016-12-16 00:19:59	2014-05-21 17:42:51	1	8
10	0	fake-58534870ed83e	new1@test.new	2016-12-16 00:20:22	2016-12-15 23:50:40	1	356
11	0	fake-585348c44c1bb	new2@test.new	2016-12-16 00:20:35	2016-12-15 23:52:04	1	357
\.


--
-- Name: usr_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('usr_id_seq', 11, true);


--
-- Name: _mesoregiao _mesoregiao_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY _mesoregiao
    ADD CONSTRAINT _mesoregiao_pkey PRIMARY KEY (gid);


--
-- Name: _microregiao _microregiao_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY _microregiao
    ADD CONSTRAINT _microregiao_pkey PRIMARY KEY (gid);


--
-- Name: _municipios _municipios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY _municipios
    ADD CONSTRAINT _municipios_pkey PRIMARY KEY (gid);


--
-- Name: agent_meta agent_meta_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent_meta
    ADD CONSTRAINT agent_meta_pk PRIMARY KEY (id);


--
-- Name: agent agent_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent
    ADD CONSTRAINT agent_pk PRIMARY KEY (id);


--
-- Name: agent_relation agent_relation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent_relation
    ADD CONSTRAINT agent_relation_pkey PRIMARY KEY (id);


--
-- Name: db_update db_update_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY db_update
    ADD CONSTRAINT db_update_pk PRIMARY KEY (name);


--
-- Name: event_meta event_meta_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_meta
    ADD CONSTRAINT event_meta_pk PRIMARY KEY (id);


--
-- Name: event_occurrence_cancellation event_occurrence_cancellation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence_cancellation
    ADD CONSTRAINT event_occurrence_cancellation_pkey PRIMARY KEY (id);


--
-- Name: event_occurrence event_occurrence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence
    ADD CONSTRAINT event_occurrence_pkey PRIMARY KEY (id);


--
-- Name: event_occurrence_recurrence event_occurrence_recurrence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence_recurrence
    ADD CONSTRAINT event_occurrence_recurrence_pkey PRIMARY KEY (id);


--
-- Name: event event_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event
    ADD CONSTRAINT event_pk PRIMARY KEY (id);


--
-- Name: file file_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY file
    ADD CONSTRAINT file_pk PRIMARY KEY (id);


--
-- Name: geo_division geo_divisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY geo_division
    ADD CONSTRAINT geo_divisions_pkey PRIMARY KEY (id);


--
-- Name: metadata metadata_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY metadata
    ADD CONSTRAINT metadata_pk PRIMARY KEY (object_id, object_type, key);


--
-- Name: metalist metalist_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY metalist
    ADD CONSTRAINT metalist_pk PRIMARY KEY (id);


--
-- Name: notification notification_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY notification
    ADD CONSTRAINT notification_pk PRIMARY KEY (id);


--
-- Name: project_event project_event_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY project_event
    ADD CONSTRAINT project_event_pk PRIMARY KEY (id);


--
-- Name: project_meta project_meta_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY project_meta
    ADD CONSTRAINT project_meta_pk PRIMARY KEY (id);


--
-- Name: project project_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY project
    ADD CONSTRAINT project_pk PRIMARY KEY (id);


--
-- Name: registration_field_configuration registration_field_configuration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY registration_field_configuration
    ADD CONSTRAINT registration_field_configuration_pkey PRIMARY KEY (id);


--
-- Name: registration_file_configuration registration_file_configuration_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY registration_file_configuration
    ADD CONSTRAINT registration_file_configuration_pkey PRIMARY KEY (id);


--
-- Name: registration_meta registration_meta_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY registration_meta
    ADD CONSTRAINT registration_meta_pk PRIMARY KEY (id);


--
-- Name: request request_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY request
    ADD CONSTRAINT request_pk PRIMARY KEY (id);


--
-- Name: role role_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY role
    ADD CONSTRAINT role_pk PRIMARY KEY (id);


--
-- Name: role role_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY role
    ADD CONSTRAINT role_unique UNIQUE (usr_id, name);


--
-- Name: seal_meta seal_meta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY seal_meta
    ADD CONSTRAINT seal_meta_pkey PRIMARY KEY (id);


--
-- Name: seal seal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY seal
    ADD CONSTRAINT seal_pkey PRIMARY KEY (id);


--
-- Name: seal_relation seal_relation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY seal_relation
    ADD CONSTRAINT seal_relation_pkey PRIMARY KEY (id);


--
-- Name: space_meta space_meta_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY space_meta
    ADD CONSTRAINT space_meta_pk PRIMARY KEY (id);


--
-- Name: space space_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY space
    ADD CONSTRAINT space_pk PRIMARY KEY (id);


--
-- Name: term term_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY term
    ADD CONSTRAINT term_pk PRIMARY KEY (id);


--
-- Name: term_relation term_relation_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY term_relation
    ADD CONSTRAINT term_relation_pk PRIMARY KEY (id);


--
-- Name: user_app user_app_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY user_app
    ADD CONSTRAINT user_app_pk PRIMARY KEY (public_key);


--
-- Name: usr usr_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY usr
    ADD CONSTRAINT usr_pk PRIMARY KEY (id);


--
-- Name: agent_meta_owner_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_meta_owner_key_index ON agent_meta USING btree (object_id, key);


--
-- Name: agent_meta_owner_key_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_meta_owner_key_value_index ON agent_meta USING btree (object_id, key, value);


--
-- Name: agent_relation_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agent_relation_all ON agent_relation USING btree (agent_id, object_type, object_id);


--
-- Name: event_meta_owner_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_meta_owner_key_index ON event_meta USING btree (object_id, key);


--
-- Name: event_meta_owner_key_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_meta_owner_key_value_index ON event_meta USING btree (object_id, key, value);


--
-- Name: event_occurrence_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_occurrence_status_index ON event_occurrence USING btree (status);


--
-- Name: file_owner_grp_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX file_owner_grp_index ON file USING btree (object_type, object_id, grp);


--
-- Name: geo_divisions_geom_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geo_divisions_geom_idx ON geo_division USING gist (geom);


--
-- Name: idx_60c85cb1166d1f9c; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_60c85cb1166d1f9c ON registration_field_configuration USING btree (project_id);


--
-- Name: owner_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX owner_index ON term_relation USING btree (object_type, object_id);


--
-- Name: project_meta_owner_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_meta_owner_key_index ON project_meta USING btree (object_id, key);


--
-- Name: project_meta_owner_key_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX project_meta_owner_key_value_index ON project_meta USING btree (object_id, key, value);


--
-- Name: registration_meta_key_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX registration_meta_key_value_index ON registration_meta USING btree (key, value);


--
-- Name: registration_meta_owner_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX registration_meta_owner_key_index ON registration_meta USING btree (object_id, key);


--
-- Name: registration_meta_owner_key_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX registration_meta_owner_key_value_index ON registration_meta USING btree (object_id, key, value);


--
-- Name: request_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX request_uid ON request USING btree (request_uid);


--
-- Name: requester_user_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX requester_user_index ON request USING btree (requester_user_id, origin_type, origin_id);


--
-- Name: space_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX space_location ON space USING gist (_geo_location);


--
-- Name: space_meta_owner_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX space_meta_owner_key_index ON space_meta USING btree (object_id, key);


--
-- Name: space_meta_owner_key_value_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX space_meta_owner_key_value_index ON space_meta USING btree (object_id, key, value);


--
-- Name: space_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX space_type ON space USING btree (type);


--
-- Name: taxonomy_term_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX taxonomy_term_unique ON term USING btree (taxonomy, term);


--
-- Name: agent agent_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent
    ADD CONSTRAINT agent_agent_fk FOREIGN KEY (parent_id) REFERENCES agent(id);


--
-- Name: agent_meta agent_agent_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent_meta
    ADD CONSTRAINT agent_agent_meta_fk FOREIGN KEY (object_id) REFERENCES agent(id);


--
-- Name: agent_relation agent_relation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent_relation
    ADD CONSTRAINT agent_relation_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: event event_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event
    ADD CONSTRAINT event_agent_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: event_occurrence event_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence
    ADD CONSTRAINT event_fk FOREIGN KEY (event_id) REFERENCES event(id);


--
-- Name: event_occurrence_cancellation event_occurrence_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence_cancellation
    ADD CONSTRAINT event_occurrence_fk FOREIGN KEY (event_occurrence_id) REFERENCES event_occurrence(id) ON DELETE CASCADE;


--
-- Name: event_occurrence_recurrence event_occurrence_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence_recurrence
    ADD CONSTRAINT event_occurrence_fk FOREIGN KEY (event_occurrence_id) REFERENCES event_occurrence(id) ON DELETE CASCADE;


--
-- Name: project_event event_project_event_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY project_event
    ADD CONSTRAINT event_project_event_fk FOREIGN KEY (event_id) REFERENCES event(id);


--
-- Name: event_meta event_project_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_meta
    ADD CONSTRAINT event_project_meta_fk FOREIGN KEY (object_id) REFERENCES event(id);


--
-- Name: file file_file_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY file
    ADD CONSTRAINT file_file_fk FOREIGN KEY (parent_id) REFERENCES file(id);


--
-- Name: registration_file_configuration fk_209c792e166d1f9c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY registration_file_configuration
    ADD CONSTRAINT fk_209c792e166d1f9c FOREIGN KEY (project_id) REFERENCES project(id);


--
-- Name: registration_field_configuration fk_60c85cb1166d1f9c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY registration_field_configuration
    ADD CONSTRAINT fk_60c85cb1166d1f9c FOREIGN KEY (project_id) REFERENCES project(id);


--
-- Name: notification notification_request_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY notification
    ADD CONSTRAINT notification_request_fk FOREIGN KEY (request_id) REFERENCES request(id);


--
-- Name: notification notification_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY notification
    ADD CONSTRAINT notification_user_fk FOREIGN KEY (user_id) REFERENCES usr(id);


--
-- Name: project project_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY project
    ADD CONSTRAINT project_agent_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: event project_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event
    ADD CONSTRAINT project_fk FOREIGN KEY (project_id) REFERENCES project(id);


--
-- Name: project_event project_project_event_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY project_event
    ADD CONSTRAINT project_project_event_fk FOREIGN KEY (project_id) REFERENCES project(id);


--
-- Name: project project_project_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY project
    ADD CONSTRAINT project_project_fk FOREIGN KEY (parent_id) REFERENCES project(id);


--
-- Name: project_meta project_project_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY project_meta
    ADD CONSTRAINT project_project_meta_fk FOREIGN KEY (object_id) REFERENCES project(id);


--
-- Name: request requester_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY request
    ADD CONSTRAINT requester_user_fk FOREIGN KEY (requester_user_id) REFERENCES usr(id);


--
-- Name: role role_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY role
    ADD CONSTRAINT role_user_fk FOREIGN KEY (usr_id) REFERENCES usr(id) ON DELETE CASCADE;


--
-- Name: seal seal_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY seal
    ADD CONSTRAINT seal_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: seal_meta seal_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY seal_meta
    ADD CONSTRAINT seal_meta_fk FOREIGN KEY (object_id) REFERENCES seal(id);


--
-- Name: seal_relation seal_relation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY seal_relation
    ADD CONSTRAINT seal_relation_fk FOREIGN KEY (seal_id) REFERENCES seal(id);


--
-- Name: space space_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY space
    ADD CONSTRAINT space_agent_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: event_occurrence space_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY event_occurrence
    ADD CONSTRAINT space_fk FOREIGN KEY (space_id) REFERENCES space(id);


--
-- Name: space space_space_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY space
    ADD CONSTRAINT space_space_fk FOREIGN KEY (parent_id) REFERENCES space(id);


--
-- Name: space_meta space_space_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY space_meta
    ADD CONSTRAINT space_space_meta_fk FOREIGN KEY (object_id) REFERENCES space(id);


--
-- Name: term_relation term_term_relation_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY term_relation
    ADD CONSTRAINT term_term_relation_fk FOREIGN KEY (term_id) REFERENCES term(id);


--
-- Name: usr user_profile_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY usr
    ADD CONSTRAINT user_profile_fk FOREIGN KEY (profile_id) REFERENCES agent(id);


--
-- Name: agent usr_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY agent
    ADD CONSTRAINT usr_agent_fk FOREIGN KEY (user_id) REFERENCES usr(id);


--
-- Name: user_app usr_user_app_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY user_app
    ADD CONSTRAINT usr_user_app_fk FOREIGN KEY (user_id) REFERENCES usr(id);


--
-- PostgreSQL database dump complete
--

