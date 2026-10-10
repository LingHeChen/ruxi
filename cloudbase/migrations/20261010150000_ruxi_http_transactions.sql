-- Server-only optimistic unit of work. Preview effects always roll back;
-- commits validate every observed result while holding the shared writer lock.
CREATE TABLE ruxi.http_commits (
  id uuid PRIMARY KEY,
  fingerprint text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
REVOKE ALL ON ruxi.http_commits FROM PUBLIC;

CREATE OR REPLACE FUNCTION ruxi.http_clock() RETURNS timestamptz
LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path=ruxi,pg_catalog AS $$
  SELECT coalesce(nullif(current_setting('ruxi.http_time',true), '')::timestamptz, clock_timestamp())
$$;
REVOKE ALL ON FUNCTION ruxi.http_clock() FROM PUBLIC;

CREATE OR REPLACE FUNCTION ruxi.http_plan(plan jsonb, commit_id uuid DEFAULT NULL, at_ms bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path=ruxi,pg_catalog AS $fn$
DECLARE
  item jsonb; result jsonb; output jsonb := '[]'::jsonb;
  data jsonb; affected bigint; statement_sql text; prior text;
BEGIN
  IF jsonb_typeof(plan) IS DISTINCT FROM 'array' OR jsonb_array_length(plan)>4096 THEN
    RAISE EXCEPTION 'invalid plan';
  END IF;
  PERFORM pg_advisory_xact_lock(787898120261010::bigint);
  IF commit_id IS NOT NULL THEN
    SELECT fingerprint INTO prior FROM ruxi.http_commits WHERE id=commit_id;
    IF FOUND THEN
      IF prior <> md5(plan::text || coalesce(at_ms::text,'')) THEN
        RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='commit fingerprint mismatch';
      END IF;
      RETURN jsonb_build_object('committed',true,'replayed',true);
    END IF;
  END IF;
  PERFORM set_config('ruxi.http_time', CASE WHEN at_ms IS NULL THEN '' ELSE to_timestamp(at_ms/1000.0)::text END, true);
  BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(plan) LOOP
      statement_sql := item->>'sql';
      IF statement_sql IS NULL OR length(statement_sql)=0 OR length(statement_sql)>8388608 THEN
        RAISE EXCEPTION 'invalid statement';
      END IF;
      IF item->>'mode'='rows' THEN
        EXECUTE 'WITH http_result AS (' || statement_sql || ') SELECT coalesce(jsonb_agg(to_jsonb(http_result)),''[]''::jsonb) FROM http_result' INTO data;
        affected := jsonb_array_length(data);
      ELSIF item->>'mode'='command' THEN
        EXECUTE statement_sql;
        GET DIAGNOSTICS affected = ROW_COUNT;
        data := '[]'::jsonb;
      ELSE
        RAISE EXCEPTION 'invalid mode';
      END IF;
      result := jsonb_build_object('rows',data,'num_rows',affected);
      IF item ? 'expect' AND item->'expect' IS DISTINCT FROM result THEN
        RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='unit of work conflict';
      END IF;
      output := output || jsonb_build_array(result);
    END LOOP;
    IF commit_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='P7654', MESSAGE='rollback preview';
    END IF;
    INSERT INTO ruxi.http_commits(id,fingerprint) VALUES(commit_id,md5(plan::text || coalesce(at_ms::text,'')));
  EXCEPTION WHEN SQLSTATE 'P7654' THEN
    -- output survives the subtransaction; every database effect is discarded.
    NULL;
  END;
  RETURN CASE WHEN commit_id IS NULL THEN jsonb_build_object('results',output)
    ELSE jsonb_build_object('committed',true) END;
END $fn$;
REVOKE ALL ON FUNCTION ruxi.http_plan(jsonb,uuid,bigint) FROM PUBLIC;

-- Freeze volatile retention clocks only during planned units of work. Outside
-- that context the original wall-clock behavior is preserved.
ALTER TABLE ruxi.account_commands ALTER COLUMN created_at SET DEFAULT floor(extract(epoch FROM ruxi.http_clock())*1000)::bigint;
ALTER TABLE ruxi.telemetry_events ALTER COLUMN received_at SET DEFAULT ruxi.http_clock();
ALTER TABLE ruxi.chat_reports ALTER COLUMN created_at SET DEFAULT ruxi.http_clock();
CREATE OR REPLACE FUNCTION ruxi.record_retention_clock() RETURNS trigger LANGUAGE plpgsql SET search_path=ruxi,pg_catalog AS $$
BEGIN
  IF TG_TABLE_NAME='rooms' THEN
    IF NEW.lifecycle IN ('finished','abandoned') AND NEW.terminal_at IS NULL THEN
      NEW.terminal_at=floor(extract(epoch FROM ruxi.http_clock())*1000)::bigint;
    END IF;
  ELSE
    IF NEW.revoked AND NEW.revoked_at IS NULL THEN
      NEW.revoked_at=floor(extract(epoch FROM ruxi.http_clock())*1000)::bigint;
    END IF;
  END IF;
  RETURN NEW;
END $$;
