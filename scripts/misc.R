
zip_path <- normalizePath("~/Downloads/archive.zip", winslash = "/")
zip_files <- unzip(zip_path, list = TRUE)
gpkg_file <- zip_files$Name[[1]]
vsi_path <- glue::glue("vsizip/{zip_path}")
gpkg_layers <- sf::st_layers(dsn = vsi_path)


georgia_boundary <- tigris::states() |>
  dplyr::filter(.data$STUSPS == "GA") |>
  sf::st_transform(4326)

georgia_wkt <- sf::st_as_text(sf::st_union(sf::st_geometry(georgia_boundary)))

gpkg_path <- "C:/Users/jimmy/Downloads/us_parcels/LR_PARCEL_NATIONWIDE_FILE_US_2026_Q1.gpkg"
gpkg_layers <- sf::st_layers(dsn = gpkg_path)
gpkg_layer <- gpkg_layers[[1]]

georgia_parcels <- sf::st_read(
  dsn = gpkg_path,
  query = glue::glue("SELECT * FROM {gpkg_layer}"),
  wkt_filter = georgia_wkt
)

georgia_random_parcel <- dplyr::slice_sample(georgia_parcels, n = 1L)

# get adjacent parcels
georgia_adjacent_parcels <- georgia_parcels |>
  sf::st_filter(
    y = georgia_random_parcel,
    .predicate = sf::st_touches
  )




mapview::mapview(georgia_random_parcel)
  