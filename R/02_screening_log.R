# ----Join and Check ----
join_data_sheets <- function(demographic, screen_log) {
  joint <- full_join(demographic, screen_log, by = "Pt_Study_no")

  if (anyNA(joint$`UR number`)) {
    stop("NA in UR number of merged excel sheets")
  }
  if (nrow(joint) != nrow(screen_log)) {
    stop(paste("Extra rows have been added. Actual:", nrow(joint), "Expected: ", nrow(screen_log)))
  }
  joint %>%
    arrange(Total_admissions, `UR number`, Admission)
}


remove_dup_screen_log_rows <- function(data) {
  # Fill missing NAs due to being screened in for cr and out for olig and vice versa
  # Remove issues with destination due to typos and APACHE_II, APACHE_III
  data %>%
    mutate(
      Dc_destination = first(Dc_destination), # Could be bad if first is NA. Change to mutate if duplicates then....
      APACHE_II = max(APACHE_II, 0, na.rm = TRUE),
      APACHE_III = max(APACHE_III, 0, na.rm = TRUE),
      APACHE_II = if_else(APACHE_II == 0, NA_real_, APACHE_II),
      APACHE_III = if_else(APACHE_III == 0, NA_real_, APACHE_III)
    )
}

find_cols <- function(text, replace, colnames) {
  data.frame(
    i = grep(paste0("^", text, "|", text, "$"), colnames, ignore.case = TRUE),
    j = grep(paste0("^", text, "|", text, "$"), colnames, ignore.case = TRUE, value = TRUE),
    stringsAsFactors = FALSE
  ) %>%
    mutate(k = gsub(text, replace, j, ignore.case = TRUE)) %>%
    setNames(., c(paste0(text, "_i"), paste0(text), "match"))
}


combine_date_time_cols <- function(df) {
  # Find matching col names and save them before pivoting df
  dttm_col <- inner_join(
    find_cols("date", "DateTime", colnames(df)),
    find_cols("time", "DateTime", colnames(df)),
    by = "match"
  ) %>%
    select(date, time, match) %>%
    pivot_longer(-match, values_to = "raw") %>%
    select(-name)

  new_col_names <- data.frame(raw = colnames(df)) %>%
    left_join(., dttm_col, by = "raw") %>%
    mutate(match = if_else(is.na(match), raw, match)) %>%
    pull(match) %>%
    unique(.)

  df %>%
    pivot_longer(
      all_of(dttm_col$raw),
      names_to = "DateTimeName",
      values_to = "DateTime"
    ) %>%
    mutate(
      DateTimeType = if_else(grepl("^time|time$", DateTimeName, ignore.case = TRUE), "Time", ""),
      DateTimeType = if_else(grepl("^date|date$", DateTimeName, ignore.case = TRUE), "Date", DateTimeType),
      DateTimeName = gsub("^time|time$|^date|date$", "DateTime", DateTimeName, ignore.case = TRUE)
    ) %>%
    pivot_wider(
      names_from = "DateTimeType",
      values_from = "DateTime"
    ) %>%
    mutate(
      datetime = if_else(
        (is.na(Date) | is.na(Time)),
        NA_character_,
        paste(format(Date, format = "%Y-%m-%d"), format(Time, format = "%H:%M:%S"))
      ),
      Date = NULL,
      Time = NULL
    ) %>%
    mutate(datetime = as_datetime(datetime, tz = "Australia/Melbourne")) %>%
    pivot_wider(
      names_from = "DateTimeName",
      values_from = "datetime"
    ) %>%
    select(all_of(new_col_names))
}


# ---- screen_log_all ----
create_screening_log <- function(cr_data, olig_data, out_data, excl_UR_numbers) {
  cr_screen_log <- join_data_sheets(cr_data$demographic, cr_data$screen_log)
  olig_screen_log <- join_data_sheets(olig_data$demographic, olig_data$screen_log)

  merge_col_names <- setdiff(
    intersect(colnames(cr_screen_log), colnames(olig_screen_log)),
    c("Incl_criteria_ok", "Pt_Study_no", "Comment")
  )

  # "_in" refers to pts that had cr or olig
  screen_log_in <- full_join(
    cr_screen_log, olig_screen_log,
    by = merge_col_names,
    suffix = c("_crch", "_olig")
  ) %>%
    group_by(`UR number`, Admission) %>%
    mutate(duplicates = n()) %>%
    arrange(desc(duplicates), `UR number`) %>%
    fill(-`UR number`, -Admission, .direction = "downup") %>%
    remove_dup_screen_log_rows() %>%
    mutate(Time_ICU_dc = if_else(duplicates > 1, max(Time_ICU_dc), Time_ICU_dc)) %>% # TODO no na.rm on this one)
    distinct() %>%
    mutate(
      duplicates = n()
    ) %>%
    arrange(desc(duplicates), `UR number`) %>%
    ungroup() %>%
    select(-duplicates)

  stopifnot(
    "NA in UR number of merged screening logs" =
      !anyNA(screen_log_in$`UR number`)
  )
  stopifnot(
    all.equal(cr_data$screen_log$`UR number`, screen_log_in$`UR number`)
  )

  # "_out" refers to pts that had neither cr or olig
  screen_log_out <- bind_rows(out_data) %>%
    distinct() %>%
    rename(`UR number` = UR, Comment_out = Comment) %>%
    group_by(`UR number`, `Date first screened`) %>%
    remove_dup_screen_log_rows() %>%
    distinct() %>%
    group_by(`UR number`) %>%
    top_n(-1, `Date first screened`) %>% # Consider not removing, then grouping by neither, arrange by date, then fill up
    ungroup()

  stopifnot(
    nrow(screen_log_out) == uniqueN(screen_log_out$`UR number`)
  )

  chrono_errors <- screen_log_out$`UR number` %in% excl_UR_numbers
  screen_log_out[chrono_errors, "Excl_criteria_ok"] <- "N"
  screen_log_out[chrono_errors, "Already_AKI"] <- "Y"

  # All URs in screen_log_out should also appear in screen_log_in
  extra_UR <- setdiff(
    unique(screen_log_out$`UR number`), unique(screen_log_in$`UR number`)
  )

  # "_full" refers to the full screening log
  screen_log_full <- full_join(
    screen_log_in, screen_log_out,
    by = intersect(colnames(screen_log_in), colnames(screen_log_out))
  ) %>%
    group_by(`UR number`) %>%
    mutate(
      Total_rows = n(),
      duplicates = Total_admissions != Total_rows,
      Event = if_else(Epis_olig == "Y", 1, 0, 0),
      Event = if_else(Epis_cr_change == "Y", 2, 0, 0) + Event,
      Event = factor(
        Event,
        levels = c(0, 1, 2, 3),
        labels = c("Neither", "Olig only", "Cr change only", "Both")
      )
    ) %>%
    group_by(`UR number`, Event) %>%
    arrange(-Total_rows, `UR number`, Event, Admission) %>%
    fill(-`UR number`, -Event, .direction = "updown") %>%
    distinct() %>%
    group_by(`UR number`) %>%
    mutate(
      Total_rows = n(),
      duplicates = Total_admissions != Total_rows
    ) %>%
    ungroup() %>%
    filter(!is.na(Admission)) %>% # Should also filter out extra_UR
    select(
      `UR number`, starts_with("Pt_Study_no"),
      starts_with("Incl_criteria"), starts_with("Epis_"), starts_with("Total_no_"),
      Dates_screened:Child, Age:Dc_destination,
      Admission, Total_admissions, Event, starts_with("Comment")
    ) %>%
    arrange(`UR number`, Admission) %>%
    combine_date_time_cols()

  stopifnot(
    "Duplicate UR numbers found" =
      nrow(screen_log_full) == nrow(cr_data$screen_log)
  )
  stopifnot(
    "Found NAs in merged UR numbers" =
      !anyNA(screen_log_full$`UR number`)
  )
  stopifnot(
    "Number of LT patients has changed" =
      sum(!is.na(screen_log_full$Pt_Study_no_crch)) ==
        uniqueN(filter(cr_data$screen_log, !is.na(Pt_Study_no))$Pt_Study_no)
  )
  stopifnot(
    "Number of L patients has changed" =
      sum(!is.na(screen_log_full$Pt_Study_no_olig)) ==
        uniqueN(filter(olig_data$screen_log, !is.na(Pt_Study_no))$Pt_Study_no)
  )

  # setdiff(
  #   c(colnames(cr_data$demographic), colnames(cr_data$screen_log), colnames(screen_log_out)),
  #   colnames(screen_log_full)
  # )
  # setdiff(
  #   colnames(screen_log_full),
  #   c(colnames(cr_data$demographic), colnames(cr_data$screen_log), colnames(screen_log_out))
  # )

  return(screen_log_full)
}


# ---- Verify APACHE  ----
verify_apache <- function(screen_log, apd_extract) {
  # "Thin" screening log for quicker matching
  screen_log_thin <- screen_log %>%
    select(`UR number`, Admission, Event, DateTime_ICU_admit, starts_with("APACHE")) %>%
    filter(!is.na(DateTime_ICU_admit)) %>%
    mutate(
      DT_start = DateTime_ICU_admit - hours(26),
      DT_end = DateTime_ICU_admit + hours(26)
    )

  # Match only on UR number and DTTM, but could also use DOB, Sex, etc.
  # Override if error > 100 (arbitrarily chosen)
  apache_replace <- apd_extract %>%
    select(
      `HRN/NIH`,
      HOSP_ADM_DTM, ICU_ADM_DTM,
      AP2score, AP3score
    ) %>%
    mutate(
      AP2score = as.numeric(AP2score),
      AP3score = as.numeric(AP3score)
    ) %>%
    fuzzy_left_join(
      screen_log_thin, .,
      by = c(
        "UR number" = "HRN/NIH",
        "DT_start"  = "ICU_ADM_DTM",
        "DT_end"    = "ICU_ADM_DTM"
      ),
      match_fun = list(`==`, `<=`, `>=`)
    ) %>%
    mutate(
      AP_error = abs(AP2score - APACHE_II) + abs(AP3score - APACHE_III),
      AP_replace = AP_error > 100 | !is.na(AP2score) & is.na(APACHE_II)
    ) %>%
    arrange(desc(AP_replace), desc(AP_error)) %>%
    filter(AP_replace) %>%
    select(`UR number`:`DateTime_ICU_admit`, AP2score:AP3score, AP_replace)

  screen_log_replaced <- left_join(
    screen_log, apache_replace,
    by = c("UR number", "DateTime_ICU_admit", "Admission", "Event")
  ) %>%
    arrange(-AP_replace) %>%
    mutate(
      APACHE_II = if_else(AP_replace, AP2score, APACHE_II, missing = APACHE_II),
      APACHE_III = if_else(AP_replace, AP3score, APACHE_III, missing = APACHE_III)
    ) %>%
    select(-AP2score:-AP_replace) %>%
    arrange(`UR number`, Admission)

  stopifnot(all.equal(screen_log_replaced$`UR number`, screen_log$`UR number`))

  return(screen_log_replaced)
}


# ---- Overview of Screening log ----
overview_screening_log <- function(screening_log) {
  screening_log %>%
    summarise(
      Admissions = n(),
      `Unique Patients` = n_distinct(`UR number`, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    kable(., caption = "Total Admissions") %>%
    print(.)

  screening_log %>%
    group_by(Excl_criteria_ok) %>%
    # Due to multiple admissions, 1 UR could have ok on one admission and not on another
    summarise(Admissions = n(), .groups = "drop") %>%
    arrange(desc(Excl_criteria_ok)) %>%
    adorn_percentages("all") %>%
    adorn_pct_formatting() %>%
    adorn_ns(position = "front") %>%
    kable(., caption = "Patients included and excluded") %>%
    print(.)

  screening_log %>%
    filter(Excl_criteria_ok == "Y") %>%
    select(`UR number`, starts_with("Epis")) %>%
    replace_na(list(
      Epis_cr_change = "N",
      Epis_olig = "N"
    )) %>%
    group_by(Epis_cr_change, Epis_olig) %>%
    summarise(Admissions = n(), .groups = "drop") %>%
    pivot_wider(names_from = Epis_olig, values_from = Admissions) %>%
    adorn_totals(c("row", "col")) %>%
    adorn_percentages("all") %>%
    adorn_pct_formatting() %>%
    adorn_ns(position = "front") %>%
    adorn_title("top", row_name = "Epis_Cr", col_name = "Epis_Olig") %>%
    kable(., caption = "Creatinine change and Oliguria Epis Total Admissions") %>%
    print(.)

  screening_log %>%
    filter(Excl_criteria_ok == "Y") %>% # Fine with and without
    select(`UR number`, starts_with("Total_no_")) %>%
    mutate(
      Total_no_cr_epis = if_else(
        is.na(Total_no_cr_epis), " 0 cr epis", sprintf("%2d cr epis", Total_no_cr_epis)
      ),
      Total_no_olig_epis = if_else(
        is.na(Total_no_olig_epis), " 0 olig epis", sprintf("%2d olig epis", Total_no_olig_epis)
      ),
    ) %>%
    group_by(Total_no_cr_epis, Total_no_olig_epis) %>%
    summarise(Admissions = n(), .groups = "drop") %>%
    pivot_wider(names_from = Total_no_olig_epis, values_from = Admissions) %>%
    adorn_totals(c("row", "col")) %>%
    rename(Epis = Total_no_cr_epis) %>%
    kable(., caption = "Creatinine change and Oliguria Episodes per Admission (Incl. criteria ok only)") %>%
    print(.)

  screening_log %>%
    filter(Excl_criteria_ok == "N") %>%
    select(`UR number`, Already_AKI:Child) %>%
    pivot_longer(-`UR number`, names_to = "Excl_reason", values_to = "Excluded") %>%
    # Single UR can have multiple exclusion reasons
    group_by(Excl_reason) %>%
    summarise(
      Admissions = sum(Excluded == "Y", na.rm = TRUE),
      `Unique Patients` = n_distinct((`UR number`[Excluded == "Y"]), na.rm = TRUE),
      .groups = "drop"
    ) %>%
    arrange(-Admissions) %>%
    adorn_totals("row") %>%
    kable(., caption = "Excluded Admissions (multi per admission possible)") %>%
    print(.)

  unique_comorbidities <- unique(gsub(",", "", unlist(strsplit(paste0(screening_log$Comorbidities, collapse = ", "), ", "))))
}
