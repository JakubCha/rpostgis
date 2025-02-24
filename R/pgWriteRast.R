## pgWriteRast

##' Write raster to PostGIS database table.
##'
##' Sends R raster to a PostGIS database table.
##' 
##' SpatRaster band names will be stored in an array in the column
##' "band_names", which will be restored in R when imported with the function
##' \code{\link[rpostgis]{pgGetRast}}.
##' 
##' Rasters from the \code{sp} and \code{raster} packages are converted to 
##' \code{terra} objects prior to insert.
##' 
##' If \code{blocks = NULL}, the number of block will vary by raster size, with
##' a default value of 100 copies of the data in the memory at any point in time.
##' If a specified number of blocks is desired, set blocks to a one or two-length 
##' integer vector. Note that fewer, larger blocks generally results in faster
##' write times.
##'
##' @param conn A connection object to a PostgreSQL database.
##' @param name A character string specifying a PostgreSQL schema in the
##' database (if necessary) and table name to hold the raster (e.g., 
##' \code{name = c("schema","table")}).
##' @param raster An terra \code{SpatRaster}; objects from the raster
##' package (\code{RasterLayer}, \code{RasterBrick}, or \code{RasterStack}); 
##' a \code{SpatialGrid*} or \code{SpatialPixels*} from sp package.
##' @param bit.depth The bit depth of the raster. Will be set to 32-bit
##'     (unsigned int, signed int, or float, depending on the data)
##'     if left null, but can be specified (as character) as one of the
##'     PostGIS pixel types (see \url{http://postgis.net/docs/RT_ST_BandPixelType.html}).
##' @param blocks Optional desired number of blocks (tiles) to split the raster
##'     into in the resulting PostGIS table. This should be specified as a
##'     one or two-length (columns, rows) integer vector. See also 'Details'.
##' @param constraints Whether to create constraints from raster data. Recommended
##'     to leave \code{TRUE} unless applying constraints manually (see
##'     \url{http://postgis.net/docs/RT_AddRasterConstraints.html}).
##'     Note that constraint notices may print to the console,
##'     depending on the PostgreSQL server settings.
##' @param overwrite Whether to overwrite the existing table (\code{name}).
##' @param append Whether to append to the existing table (\code{name}).
##' @param progress whether to show a progress bar (TRUE by default). The progress
##'     bar mark the progress of writing blocks into the database.
##'     
##' @author David Bucklin \email{david.bucklin@@gmail.com} and Adrián Cidre 
##' González \email{adrian.cidre@@gmail.com}
##' @importFrom terra crs res blocks ext t values values<- nlyr as.matrix
##' @importFrom sp SpatialPixelsDataFrame
##' @importFrom sf st_crs
##' @importFrom methods as
##' @importFrom purrr pmap
##' @export
##' @return TRUE for successful import.
##' 
##' @seealso Function follows process from 
##' \url{http://postgis.net/docs/using_raster_dataman.html#RT_Creating_Rasters}.
##' @examples
##' \dontrun{
##' pgWriteRast(conn, c("schema", "tablename"), raster_name)
##'
##' # basic test
##' r <- terra::rast(nrows=180, ncols=360, xmin=-180, xmax=180,
##'     ymin=-90, ymax=90, vals=1)
##' pgWriteRast(conn, c("schema", "test"), raster = r,
##'     bit.depth = "2BUI", overwrite = TRUE)
##' }

pgWriteRast <- function(conn, name, raster, bit.depth = NULL, blocks = NULL, 
                        constraints = TRUE, overwrite = FALSE, append = FALSE,
                        progress = TRUE) {
  
  dbConnCheck(conn)
  if (!suppressMessages(pgPostGIS(conn))) {
    stop("PostGIS is not enabled on this database.")
  }
  
  r_class <- dbQuoteString(conn, class(raster)[1])
  
  # sp-handling
  if (class(raster)[1] %in% c("SpatialPixelsDataFrame","SpatialGridDataFrame","SpatialGrid","SpatialPixels")) {
    if (class(raster)[1] %in% c("SpatialGrid", "SpatialPixels") || length(raster@data) < 2) {
      # SpatialPixels needs a value
      if (inherits(raster, "SpatialPixels")) raster <- SpatialPixelsDataFrame(raster, data = data.frame(rep(0, length(raster))))
      raster <- as(raster, "RasterLayer")
    } else {
      raster <- as(raster, "RasterBrick")
    }
  }
  
  # raster-handling
  if (class(raster)[1] %in% c("RasterLayer", "RasterBrick", "RasterStack")) {
    raster <- methods::as(raster, "SpatRaster")
  }
  
  # crs
  r_crs <- dbQuoteString(conn, terra::crs(raster))
  
  nameq <- dbTableNameFix(conn, name)
  namef <- dbTableNameFix(conn, name, as.identifier = FALSE)
  
  if (overwrite) {
    dbDrop(conn, name, ifexists = TRUE)
  }
  
  if (!dbExistsTable(conn, name, table.only = F)) {
    # 1. create raster table
    tmp.query <- paste0("CREATE TABLE ", paste(nameq, collapse = "."), 
                        " (rid serial primary key, band_names text[], r_class character varying, r_proj4 character varying, rast raster);")
    ## If the execute fails, postgis.raster extension is not installed?
    tryCatch(
      {
        dbExecute(conn, tmp.query)
      },
      error = function(e) {
        stop('Check if postgis.raster extension is created in the database.')
        print(e)
      }
    )
  
    n.base <- 0
    append <- F
  } else {
    if (!append) {stop("Need to specify `append = TRUE` to add raster to an existing table.")}
    message("Appending to existing table. Dropping any existing raster constraints...")
    try(dbExecute(conn, paste0("SELECT DropRasterConstraints('", namef[1], "','", namef[2], "','rast',",
                               paste(rep("TRUE", 12), collapse = ","),");")))
    n.base <- dbGetQuery(conn, paste0("SELECT max(rid) r from ", paste(nameq, collapse = "."), ";"))$r
  }
  
  r1 <- raster
  res <- round(terra::res(r1), 10)
  
  # figure out block size
  if (!is.null(blocks)) {
    bs <- bs(r1, blocks)
    tr <- bs$tr
    cr <- bs$cr
  } else {
    tr <- terra::blocks(r1[[1]], 100)
    cr <- terra::blocks(terra::t(r1[[1]]), 100)
  }
  
  message("Splitting ",length(names(r1))," band(s) into ", cr$n, " x ", tr$n, " blocks...")
  
  # figure out bit depth
  if (is.null(bit.depth)) {
    if (is.integer(terra::values(r1))) {
      if (min(terra::values(r1), na.rm = TRUE) >= 0) {
        bit.depth <- "32BUI"
      } else {
        bit.depth <- "32BSI"
      }
    } else {
      bit.depth <- "32BF"
    }
  }
  bit.depth <- dbQuoteString(conn, bit.depth)
  ndval <- -99999
  
  # band names
  bnds <- dbQuoteString(conn, paste0("{{",paste(names(r1),collapse = "},{"),"}}"))
  
  srid <- 0
  try(srid <- suppressMessages(pgSRID(conn, sf::st_crs(terra::crs(r1)), create.srid = TRUE)),
      silent = TRUE)
  
  # Warning about no CRS
  if (length(srid) == 1) {
    if (srid == 0) warning("The raster has no CRS specified.")
  }
  
  # Grid with all band/block combinations
  crossed_df <- expand.grid(trn = 1:tr$n, 
                            crn = 1:cr$n,
                            band = 1:terra::nlyr(r1))
  
  n <- unlist(tapply(crossed_df$band, 
                     crossed_df$band,
                     function(x) seq(from = n.base + 1, by = 1, length.out = length(x))))
  
  rgrid <- cbind(crossed_df, n = n)
  
  
  # Function to export a block
  export_block <- function(band, trn, crn, n) {
    
    # Get band b
    rb <- r1[[band]]
    
    # rid counter
    # n <- n.base
    
    # Handle empty data rasters by setting ndval (-99999) to all values
    if (all(is.na(values(rb)))) values(rb) <- ndval
    
    # Get raster tile
    suppressWarnings(r <- rb[tr$row[trn]:(tr$row[trn] + tr$nrows[trn] - 1),
                             cr$row[crn]:(cr$row[crn] + cr$nrows[crn] - 1), 
                             drop = FALSE])
    
    # Get extent and dimensions of tile
    ex <- terra::ext(r)
    d <- dim(r)
    
    # rid counter
    # n <- n + 1
    
    # Only ST_MakeEmptyRaster/ST_AddBand during first band loop
    if (band == 1) {
      
      # Create empty raster
      tmp.query <- paste0("INSERT INTO ", paste(nameq, 
                                                collapse = "."), " (rid, band_names, r_class, r_proj4, rast) VALUES (",n, 
                          ",",bnds,",",r_class,",",r_crs,", ST_MakeEmptyRaster(", 
                          d[2], ",", d[1], ",", ex[1], ",", ex[4], ",", 
                          res[1], ",", -res[2], ", 0, 0,", srid[1], ") );")
      dbExecute(conn, tmp.query)
      
      # Upper left x/y for alignment snapping
      # if (trn == 1 & crn == 1) {
      tmp.query <- paste0("SELECT ST_UpperLeftX(rast) x FROM ", paste(nameq, collapse = ".") ," where rid = 1;")
      upx <- dbGetQuery(conn, tmp.query)$x
      tmp.query <- paste0("SELECT ST_UpperLeftY(rast) y FROM ", paste(nameq, collapse = ".") ," where rid = 1;")
      upy <- dbGetQuery(conn, tmp.query)$y
      # }
      
      # New band
      if (res[1] != res[2]) s2g <- paste0(", ", res[1], ", ", -res[2]) else s2g <- NULL
      bndargs <- paste0("ROW(",1:length(names(r1)),",",bit.depth,"::text,0,", ndval,")")
      tmp.query <- paste0("UPDATE ", paste(nameq, collapse = "."), 
                          " SET rast = ST_SnapToGrid(ST_AddBand(rast,ARRAY[",
                          paste(bndargs,collapse = ","),"]::addbandarg[]), ", upx, "," , upy , s2g, ") ", 
                          "where rid = ", 
                          n, ";")
      dbExecute(conn, tmp.query)
      
    }
    
    #
    mr <- terra::as.matrix(r, wide = TRUE)
    mr[is.na(mr)] <- ndval
    r2 <- paste(apply(mr, 1, FUN = function(x) {
      paste0("[", paste(x, collapse = ","), "]")
    }), collapse = ",")
    
    tmp.query <- paste0("UPDATE ", paste(nameq, collapse = "."), 
                        " SET rast = ST_SetValues(rast,",band,", 1, 1, ARRAY[", 
                        r2, "]::double precision[][])
                               where rid = ", 
                        n, ";")
    dbExecute(conn, tmp.query)
    
  }
  
  # Iterate over the blocks and show progress
  if (progress) {
    purrr::pmap(list(rgrid$band, rgrid$trn, rgrid$crn, rgrid$n), export_block, 
                .progress = "Writing blocks")
  } else {
    purrr::pmap(list(rgrid$band, rgrid$trn, rgrid$crn, rgrid$n), export_block)
  }
  
  
  # Create index
  if (append) {
    tmp.query <- paste0("DROP INDEX ", gsub("\"", "", paste(nameq, collapse = ".")), "_rast_st_conhull_idx")
    dbExecute(conn, tmp.query)
  }
  tmp.query <- paste0("CREATE INDEX ", gsub("\"", "", nameq[2]), 
                      "_rast_st_conhull_idx ON ", paste(nameq, collapse = "."), 
                      " USING gist( ST_ConvexHull(rast) );")
  dbExecute(conn, tmp.query)
  
  if (constraints) {
    # 5. add raster constraints
    tmp.query <- paste0("SELECT AddRasterConstraints(", dbQuoteString(conn, 
                                                                      namef[1]), "::name,", dbQuoteString(conn, namef[2]), 
                        "::name, 'rast'::name);")
    dbExecute(conn, tmp.query)
  }
  
  return(TRUE)
}