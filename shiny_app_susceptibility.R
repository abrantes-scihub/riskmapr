## Back end for susceptibility BN

library(rgdal)
library(shiny)
library(raster)
library(zip)
library(sp)
library(truncnorm)
library(stringr)
library(visNetwork)

## Set up option for maximum file input size
options(shiny.maxRequestSize=50*1024^2) # please, please, please try to be conservative with upload sizes

ui <- fluidPage(
  
  # App title
  
  titlePanel("Rapid weed riskmapr - susceptibility model"),
  
  # Sidebar panel for inputs ----
  
  sidebarLayout(
    
    sidebarPanel(width = 6,
      
      # Input: Select a file ----
      
      fileInput(
        "establishment", 
        "Upload spatial proxies for risk factors (establishment) (.tif extension, allows multiple)",
        multiple = TRUE,
        accept = c(".tif")
      ),
      
      helpText("Select spatial proxies for all identified risk factors affecting plant establishment at once and click 'Open'. Files are automatically uploaded in alphabetical order. Upload limit is 50MB, but app functionality has only been confirmed for total upload sizes < 15MB."),
      
      textInput(
        "establishment_weights",
        "Risk factor weights (establishment)"
      ),
      
      helpText("Enter numerical weights for all identified risk factors affecting plant establishment. Weights must equal '1', '2' or '3', be separated by commas and ordered alphabetically by spatial proxy name."),
      
      numericInput(
        "est_sd", 
        "Standard deviation (establishment)",
        value = 15,
        min = 0.1,
        max = 100
      ),
      
      helpText("Enter the standard deviation used for computing the CPT of plant establishment from its weighted risk factors. The default is '15'. This may be changed to any reasonable value in the range [0.1,100] where appropriate."),
      
      fileInput(
        "persistence", 
        "Upload spatial proxies for risk factors (persistence) (.tif extension, allows multiple)",
        multiple = TRUE,
        accept = c(".tif")
      ),
      
      helpText("Select spatial proxies for all identified risk factors affecting plant persistence at once and click 'Open'. For details, see above."),
      
      textInput(
        "persistence_weights",
        "Risk factor weights (persistence)"
      ),
      
      helpText("Enter numerical weights for all identified risk factors affecting plant persistence. For details, see above."),
      
      numericInput(
        "per_sd", 
        "Standard deviation (persistence)",
        value = 15,
        min = 0.1,
        max = 100
      ),
      
      helpText("Enter the standard deviation used for computing the CPT of plant persistence. For details, see above."),
      
      fileInput(
        "propagule_pressure", 
        "Upload spatial proxies for risk factors (propagule pressure) (.tif extension, allows multiple)",
        multiple = TRUE,
        accept = c(".tif")
      ),
      
      helpText("elect spatial proxies for all identified risk factors affecting propagule pressure at once and click 'Open'. For details, see above."),
      
      textInput(
        "propagule_weights",
        "Risk factor weights (propagule pressure)"
      ),
      
      helpText("Enter numerical weights for all identified risk factors affecting propagule pressure. For details, see above."),
      
      numericInput(
        "prg_sd", 
        "Standard deviation (propagule pressure)",
        value = 15,
        min = 0.1,
        max = 100
      ),
      
      helpText("Enter the standard deviation used for computing the CPT of propagule pressure. For details, see above."),
 
      numericInput(
        "suitability_sd", 
        "Standard deviation (suitability)",
        value = 10,
        min = 0.1,
        max = 100
      ),

      helpText("Enter the standard deviation used for computing the CPT of invasion risk (suitability) as a function of plant establishment and persistence. The default is '10' in order to limit the propagated uncertainty in the model, but may be changed to any reasonable value in the range [0.1,100]."),
      
      numericInput(
        "susceptibility_sd", 
        "Standard deviation (susceptiblity)",
        value = 10,
        min = 0.1,
        max = 100
      ),

      helpText("Enter the standard deviation used for computing the CPT of invasion risk (susceptibility) as a function of suitability and propagule pressure. For details, see above."),
      
      textInput(
        "suit_name",
        "Optional: name risk map (suitability) (no extension)",
        "Suitability"
      ),
      
      textInput(
        "susc_name",
        "Optional: name risk map (susceptibility) (no extension)",
        "Susceptibility"
      ),
      
      helpText("Choose a descriptive name for the generated risk maps. must be specified before running the tool."),
      
      actionButton("validate", "VISUALIZE RISK MODEL"),
      
      helpText("Click to visualize and validate the structure of your risk model (susceptibility). The model is displayed on the right-hand panel, showing uploaded spatial proxies colour-coded by assigned risk factor weights."),
      
      actionButton("submit", "RUN RISK MODEL"),
      
      helpText("Click to run your risk model (susceptibility). Four spatial files (.TIF) are generated: suitability and susceptibility index maps (the expected values), and uncertainty maps for each (the standard deviations) This should take no longer than 1-2 minutes, depending on the size of spatial proxies. Once completed, the risk map is displayed on the right-hand panel."),

      downloadButton(outputId = "downloadData", label = "DOWNLOAD RISK MAP"),
      
      helpText("Once the risk maps have been generated and displayed, click to download zipped .TIF files (suitability and susceptibility index maps + uncertainty maps).")

    ),
    
    mainPanel(width = 6,
      visNetworkOutput("valiplot"),
      plotOutput("mainplot")
    )
    
  )
  
)


server <- function(input, output){
  
  the_graph <- eventReactive(input$validate, {
    
    ### Two functions needed for colourmapping the network edges
    colour_labeller <- function(wt) switch(
      wt, "1" = "forestgreen", "2" = "orange", "3" = "red"
    )
    colour_labeller_vectorised <- function(wts){
      if(!all(wts %in% 1:3)){
        stop("All weights must be 1, 2, or 3")
      }
      unlist(
        lapply(wts, colour_labeller)
      )
    }
    
    ### Get inputs for model validation
    req(input$persistence)
    req(input$persistence_weights)
    req(input$establishment)
    req(input$establishment_weights)
    req(input$propagule_pressure)
    req(input$propagule_weights)
    
    ### Preprocess the inputs 
    persistence <- input$persistence
    persistence <- persistence$name
    persistence <- gsub(".tif", "", persistence)
    persistence_wts <- input$persistence_weights
    persistence_wts <- str_split(persistence_wts, "[,/;\t]{1}")[[1]]
    persistence_wts <- as.numeric(persistence_wts)
    establishment <- input$establishment
    establishment <- establishment$name
    establishment <- gsub(".tif", "", establishment)
    establishment_wts <- input$establishment_weights
    establishment_wts <- str_split(establishment_wts, "[,/;\t]{1}")[[1]]
    establishment_wts <- as.numeric(establishment_wts)
    propagule <- input$propagule_pressure
    propagule <- propagule$name
    propagule <- gsub(".tif", "", propagule)
    propagule_wts <- input$propagule_weights
    propagule_wts <- str_split(propagule_wts, "[,/;\t]{1}")[[1]]
    propagule_wts <- as.numeric(propagule_wts)
    
    ### Lay out basic network structure (five essential nodes)
    basic_network <- data.frame(
      from = c(1, 2, 3, 4),
      to = c(3, 3, 5, 5),
      arrows = "to"
    )
    
    vertex_info <- data.frame(
      id = 1:5, 
      label = c(
        "Establishment", 
        "Persistence",
        "Suitability", 
        "Propagule\npressure", 
        "Susceptibility"
      ),
      value = 1:5,
      group = "Not user-specified",
      shape = rep("box", 5),
      color = "black",
      font.color = "white",
      shadow = rep(TRUE, 5)
    )
    
    ### Add to basic network structure based on inputs
    n_est <- length(establishment)
    n_per <- length(persistence)
    n_prg <- length(propagule)
    est_id <- 6:(5 + n_est)
    per_id <- (max(est_id) + 1):(max(est_id) + n_per)
    prg_id <- (max(per_id) + 1):(max(per_id) + n_prg)
    
    new_connections <- data.frame(
      from = c(est_id, per_id, prg_id),
      to   = c(rep(1, n_est), rep(2, n_per), rep(4, n_prg)),
      arrows = "to"
    )
    
    n_elem <- length(c(establishment, persistence, propagule))
    new_vertex_info <- data.frame(
      id = c(est_id, per_id, prg_id), 
      label = c(establishment, persistence, propagule),
      value = c(est_id, per_id, prg_id),
      group = paste("Weight =", c(establishment_wts, persistence_wts, propagule_wts)),
      shape = rep("ellipse", n_elem),
      color = colour_labeller_vectorised(c(establishment_wts, persistence_wts, propagule_wts)),
      font.color = "white",
      shadow = rep(FALSE, n_elem)
    )
    
    all_network <- rbind(
      basic_network,
      new_connections
    )
    all_vertex <- rbind(
      vertex_info,
      new_vertex_info
    )
    
    the_graph <- visNetwork(all_vertex, all_network, height = "600px", width = "100%") %>% #,
      visGroups(groupname = "Weight = 1", color = "forestgreen", font = list(color = "white")) %>%
      visGroups(groupname = "Weight = 2", color = "orange", font = list(color = "white")) %>%
      visGroups(groupname = "Weight = 3", color = "red", font = list(color = "white")) %>%
      visGroups(groupname = "Not user-specified", color = "black", shape = "box", font = list(color = "white")) %>%
      visLegend(main = "Legend") %>%
      visPhysics(enabled = FALSE)
    
    the_graph
    
  }
  )
  
  output$valiplot <- renderVisNetwork(
    {
      
      the_graph()
      
    }
  )
  
  the_plots <- eventReactive(input$submit, {
    
    ### Define functions for finding expectations and standard deviations
    exp_discrete <- function(x){
      p <- x
      s <- as.numeric(names(x))
      sum(p * s)
    }
    ex2_discrete <- function(x){
      p <- x
      s <- as.numeric(names(x))
      sum(p * (s^2))
    }
    std_discrete <- function(x){
      sqrt(ex2_discrete(x) - exp_discrete(x)^2)
    }
    unique_out_of_memory <- function(x){
      # MODIFIED SOURCE CODE FROM THE PACKAGE 'RASTER', FROM FUNCTION raster::unique().
      # MODIFIED 5 FEB, 2019
      nl <- nlayers(x)
      un <- list(length = nl, mode = "list")
      tr <- blockSize(x, n = nl)
      un <- NULL
      for (i in 1:tr$n) {
        v <- dplyr::distinct(as.data.frame(getValues(x, row = tr$row[i], nrows = tr$nrows[i])))
        un <- rbind(v, un)
      }
      return(un)
    }
    
    ### Get inputs
    req(input$persistence)
    req(input$persistence_weights)
    req(input$establishment)
    req(input$establishment_weights)
    req(input$propagule_pressure)
    req(input$propagule_weights)
    
    ### Get persistence and establishment as rasters
    persistence <- input$persistence
    persistence <- persistence$datapath
    persistence_wts <- input$persistence_weights
    persistence_wts <- str_split(persistence_wts, "[,/;\t]{1}")[[1]]
    persistence_wts <- as.numeric(persistence_wts)
    persistence_sd <- input$per_sd
    establishment <- input$establishment
    establishment <- establishment$datapath
    establishment_wts <- input$establishment_weights
    establishment_wts <- str_split(establishment_wts, "[,/;\t]{1}")[[1]]
    establishment_wts <- as.numeric(establishment_wts)
    establishment_sd <- input$est_sd
    propagule <- input$propagule_pressure
    propagule <- propagule$datapath
    propagule_wts <- input$propagule_weights
    propagule_wts <- str_split(propagule_wts, "[,/;\t]{1}")[[1]]
    propagule_wts <- as.numeric(propagule_wts)
    propagule_sd <- input$prg_sd
    
    ## Standard deviations of suitability and susceptibility nodes
    suitability_sd <- input$suitability_sd
    susceptibility_sd <- input$susceptibility_sd
    
    ## Find length of names
    nn_per <- length(persistence)
    nn_est <- length(establishment)
    nn_pgl <- length(propagule)
    
    ## Check that lengths are what they should be
    
    if(nn_per != length(persistence_wts)){
      stop("The number of persistence weights is not equal to the number of proxy rasters provided.")
    }
    if(nn_est != length(establishment_wts)){
      stop("The number of establishment weights is not equal to the number of proxy rasters provided.")
    }
    if(nn_pgl != length(propagule_wts)){
      stop("The number of propagule weights is not equal to the number of proxy rasters provided.")
    }
    
    ## Construct indices, persistence first
    i_per <- 1:nn_per
    i_est <- (nn_per + 1):(nn_per + nn_est)
    i_prg <- (nn_per + nn_est + 1):(nn_per + nn_est + nn_pgl)
    
    ## Read in rasters as stack
    suit_ras <- stack(c(persistence, establishment, propagule))

    ## Extract distinct rows WITHOUT rows involving NAs.
    message("Finding the unique combinations of proxies")
    suit_ras_df_dn <- unique_out_of_memory(suit_ras) 
    suit_ras_df_dn <- dplyr::distinct(suit_ras_df_dn)
    
    ## Remove meaningless combinations, NAs, etc.
    message("Getting rid of meaningless combinations of values")
    ind_na <- rowSums(is.na(suit_ras_df_dn)) == 0
    suit_ras_df_dn <- suit_ras_df_dn[ind_na, ]
    ind_rn <- rowSums(suit_ras_df_dn < 0 | suit_ras_df_dn > 100) == 0
    suit_ras_df_dn <- suit_ras_df_dn[ind_rn, ]
    rm(ind_rn, ind_na)
    gc()
    
    # Subsets as required for the analysis
    per_wets <- persistence_wts 
    est_wets <- establishment_wts 
    prg_wets <- propagule_wts
    
    # Empty numeric vectors
    st <- st_sd <- sc <- sc_sd <- numeric(nrow(suit_ras_df_dn))
    # Main loop
    message("Starting the main loop")
    for(i in 1:nrow(suit_ras_df_dn)){
      
      # Establishment
      est_vars <- suit_ras_df_dn[i, i_est]
      est_mean <- sum(est_vars * est_wets)/sum(est_wets)
      est <- dtruncnorm(seq(0, 100, 25), 0, 100, est_mean, establishment_sd)
      est <- est/sum(est)
      names(est) <- seq(0, 100, 25)
      
      # Persistence
      per_vars <- suit_ras_df_dn[i, i_per]
      per_mean <- sum(per_vars * per_wets)/sum(per_wets)
      per <- dtruncnorm(seq(0, 100, 25), 0, 100, per_mean, persistence_sd)
      per <- per/sum(per)
      names(per) <- seq(0, 100, 25)
      
      # Suitability by marginalisation using law of total probability
      n_est <- length(est)
      n_per <- length(per)
      j_mat <- matrix(0, nrow = n_est * n_per, ncol = 5)
      cnt <- 1
      est_x <- as.numeric(names(est))
      per_x <- as.numeric(names(per))
      for(j in 1:n_est){
        for(k in 1:n_per){
          p_jk <- dtruncnorm(seq(0, 100, 25), 0, 100, (sum(est_wets) * est_x[j] + sum(per_wets) * per_x[k])/(sum(est_wets) + sum(per_wets)), suitability_sd)
          j_mat[cnt, ] <- p_jk/sum(p_jk) * est[j] * per[k]
          cnt <- cnt + 1
        }
      }
      suit <- colSums(j_mat)
      names(suit) <- seq(0, 100, 25)
      suit_wets <- sum(est_wets) + sum(per_wets)
      
      # Take expectation as prediction
      st[i] <- exp_discrete(suit)
      st_sd[i] <- std_discrete(suit)
      
      # Now construct the propagule pressure node
      prg_vars <- suit_ras_df_dn[i, i_prg]
      prg_mean <- sum(prg_vars * prg_wets)/sum(prg_wets)
      prg <- dtruncnorm(seq(0, 100, 25), 0, 100, prg_mean, propagule_sd)
      prg <- prg/sum(prg)
      names(prg) <- seq(0, 100, 25)
      
      # Now construct the susceptibility node
      n_prg <- length(prg)
      n_sut <- length(suit)
      j_mat <- matrix(0, nrow = n_sut * n_prg, ncol = 5)
      cnt <- 1
      suit_x <- as.numeric(names(suit))
      prg_x <- as.numeric(names(prg))
      for(j in 1:n_sut){
        for(k in 1:n_prg){
          p_jk <- dtruncnorm(seq(0, 100, 25), 0, 100, (sum(suit_wets) * suit_x[j] + sum(prg_wets) * prg_x[k])/(sum(suit_wets) + sum(prg_wets)), susceptibility_sd)
          j_mat[cnt, ] <- p_jk/sum(p_jk) * suit[j] * prg[k]
          cnt <- cnt + 1
        }
      }
      susc <- colSums(j_mat)
      names(susc) <- seq(0, 100, 25)
      
      # Take expectation as the prediction
      sc[i] <- exp_discrete(susc)
      sc_sd[i] <- std_discrete(susc)
    }
    message("Exited from the main loop")
    
    # Derive ID column
    suit_ras_df_dn <- as.data.frame(suit_ras_df_dn)
    suit_ras_df_dn$Suitability <- st 
    suit_ras_df_dn$Susceptibility <- sc 
    rm(st, sc)
    suit_ras_df_dn$Suitability_SD <- st_sd
    suit_ras_df_dn$Susceptibility_SD <- sc_sd
    rm(st_sd, sc_sd)
    gc()
    
    # Begin the process of joining this back to the full dataset, all done by manipulating the files and without ingesting the entire raster into memory
    chunk_info <- blockSize(suit_ras, n = nlayers(suit_ras), minblocks = nlayers(suit_ras))

    # Prepare to write by constructing file names
    suit_fn <- paste0(input$suit_name, ".tif")
    suit_sd_fn <- paste0(input$suit_name, "_SD.tif")
    susc_fn <- paste0(input$susc_name, ".tif")
    susc_sd_fn <- paste0(input$susc_name, "_SD.tif")
    
    # Remove existing .tif files so they don't get packaged up 
    if(length(Sys.glob("*.tif")) > 0){
      file.remove(Sys.glob("*.tif"))
    }
    
    # Open file connections
    message("Preparing to write rasters for suitability and susceptibility, plus uncertainty maps.")
    f1 <- writeStart(suit_ras[[1]], suit_fn, overwrite = TRUE)
    f2 <- writeStart(suit_ras[[1]], suit_sd_fn, overwrite = TRUE)
    f3 <- writeStart(suit_ras[[1]], susc_fn, overwrite = TRUE)
    f4 <- writeStart(suit_ras[[1]], susc_sd_fn, overwrite = TRUE)
    
    # Then the loop, ingesting the raster by chunks, writing it by the same chunks
    for(i in 1:chunk_info$n){
      tmp_df <- as.data.frame(
        getValues(suit_ras, row = chunk_info$row[i], nrows = chunk_info$nrows[i])
      )
      vals_df <- dplyr::left_join(
        tmp_df, 
        suit_ras_df_dn, 
        by = names(tmp_df)
      )
      rm(tmp_df)
      gc()
      f1 <- writeValues(f1, vals_df$Suitability, chunk_info$row[i])
      f3 <- writeValues(f3, vals_df$Susceptibility, chunk_info$row[i])
      f2 <- writeValues(f2, vals_df$Suitability_SD, chunk_info$row[i])
      f4 <- writeValues(f4, vals_df$Susceptibility_SD, chunk_info$row[i])
      rm(vals_df)
      gc()
    }
    f1 <- writeStop(f1)
    f2 <- writeStop(f2)
    f3 <- writeStop(f3)
    f4 <- writeStop(f4)
    rm(f1, f2, f3, f4)
    gc()
    
    # Reading in files for display
    message("Rasters ready for display")
    suit_ras <- stack(c(suit_fn, susc_fn))
    suit_ras
    
  })
  
  output$mainplot <- renderPlot(
    {
      
      ### Plot
      spplot(the_plots())
      
    }
  )
  
  output$downloadData <- downloadHandler(
    
    filename = "Raster_Exports.zip",
    content = function(file){
      # Files have already been created, so here we just zip them up. 
      zip(zipfile = file, files = Sys.glob("*.tif"))
    },
    contentType = "application/zip"
    
  )
  
}

shinyApp(ui, server)