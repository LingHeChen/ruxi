# Bootstrap namespace explicitly. Application queries never fall back to public.
{:ok, _} = Ruxi.Repo.start_link()
Ruxi.DB.query("CREATE SCHEMA IF NOT EXISTS ruxi")
Ruxi.DB.query("REVOKE ALL ON SCHEMA ruxi FROM PUBLIC")
IO.puts("Ruxi schema prepared; migration and business tables stay in ruxi.")
