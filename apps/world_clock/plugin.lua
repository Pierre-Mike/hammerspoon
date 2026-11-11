return {
  id          = "world_clock",
  name        = "World clock",
  version     = "1.0.0",
  api         = 1,
  author      = "Pierre-Mike",
  description = "The time in other cities, on the hub panel.",
  settings = {
    -- City names from the tile's list, comma separated. An entry written as
    -- "Label=Area/Zone" adds a city the list does not have.
    cities = { type = "string", default = "Seattle,New York,Paris" },
  },
}
