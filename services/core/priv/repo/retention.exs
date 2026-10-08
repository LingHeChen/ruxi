case Ruxi.Retention.run() do
  {:ok, result} -> IO.inspect(result, label: "Retention batch")
  {:error, error} -> raise "Retention failed: #{inspect(error)}"
end
