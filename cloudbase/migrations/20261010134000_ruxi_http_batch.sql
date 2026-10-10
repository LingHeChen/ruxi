CREATE OR REPLACE FUNCTION ruxi.http_batch(statements jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ruxi, pg_catalog
AS $function$
DECLARE
  statement jsonb;
  statement_sql text;
  statement_rows jsonb;
  affected bigint;
  results jsonb := '[]'::jsonb;
BEGIN
  IF jsonb_typeof(statements) IS DISTINCT FROM 'array' OR jsonb_array_length(statements) > 256 THEN
    RAISE EXCEPTION 'invalid batch';
  END IF;
  FOR statement IN SELECT value FROM jsonb_array_elements(statements) LOOP
    statement_sql := statement->>'sql';
    IF statement_sql IS NULL OR length(statement_sql) = 0 OR length(statement_sql) > 1048576 THEN
      RAISE EXCEPTION 'invalid statement';
    END IF;
    IF statement->>'mode' = 'rows' THEN
      EXECUTE 'WITH ruxi_http_result AS (' || statement_sql || ') SELECT coalesce(jsonb_agg(to_jsonb(ruxi_http_result)), ''[]''::jsonb) FROM ruxi_http_result'
        INTO statement_rows;
      affected := jsonb_array_length(statement_rows);
    ELSIF statement->>'mode' = 'command' THEN
      EXECUTE statement_sql;
      GET DIAGNOSTICS affected = ROW_COUNT;
      statement_rows := '[]'::jsonb;
    ELSE
      RAISE EXCEPTION 'invalid statement mode';
    END IF;
    results := results || jsonb_build_array(jsonb_build_object('rows', statement_rows, 'num_rows', affected));
  END LOOP;
  RETURN results;
END
$function$;

REVOKE ALL ON FUNCTION ruxi.http_batch(jsonb) FROM PUBLIC;
