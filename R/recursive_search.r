

#' Recursive search tokens
#'
#' @param tokens   The tokenIndex
#' @param ids      A data.table with global ids (doc_id,sentence,token_id). 
#' @param ql       a list of queriers (possibly the list nested in another query, or containing nested queries)
#' @param block    A data.table with global ids (doc_id,sentence,token_id) for excluding nodes from the search
rec_find <- function(tokens, ids, ql, block=NULL, fill=T) {
  .DROP = NULL
  out_req = list()
  out_not_req = list()
  for (i in seq_along(ql)) {
    q = ql[[i]]
    #if (only_req && !q$req) next   ## only look for required nodes. unrequired nodes are added afterwards with add_unrequired()
    if (!fill && is(q, 'tQueryFill')) next   
    
    if (is.na(q$label)) {
      q$label = paste('.DROP', i) ## if label is not used, the temporary .DROP name is used to hold the queries during search. .DROP columns are removed when no longer needed
    } 
    
    selection = rec_selection(tokens, ids, q, block, fill)
    

    if (q$NOT) {
      if (nrow(selection) > 0) {
        selection = data.table::fsetdiff(data.table::data.table(ids[,1],ids[,2], .MATCH_ID=ids[[3]]), selection[,c('doc_id','sentence','.MATCH_ID')])
      } else selection = data.table::data.table(ids[,1], ids[,2], .MATCH_ID=ids[[3]])
      selection[,.DROP := NA]
    }
    
    if (q$req) {
      if (nrow(selection) == 0) return(selection)
      out_req[['']] = selection
      if ('.DROP' %in% colnames(selection)) selection[,.DROP := NULL]
      block = get_long_ids(block, selection)
    } else {
      out_not_req[['']] = selection
    }
  }
  
  has_req = length(out_req) > 0  
  has_not_req = length(out_not_req) > 0  
  
  if (has_req && !has_not_req) 
    out = merge_req(out_req)
  if (!has_req && has_not_req)
    out = merge_not_req(out_not_req)
  if (has_req && has_not_req)
    out = merge_req_and_not_req(out_req, out_not_req)
  if (!has_req && !has_not_req)
    out = data.table::data.table()
  
  #if (!q$label == '.DROP' && nrow(out) > 0) {
  #  parcol = paste0(q$label, '_PARENT') 
  #  out[, (parcol) := .MATCH_ID]
  #}
  out
}

rec_selection <- function(tokens, ids, q, block, fill) {
  selection = select_tokens(tokens, ids=ids, q=q, block=block)
  if (length(q$nested) > 0 & length(selection) > 0) {
    nested = rec_find(tokens, ids=selection[,c('doc_id','sentence',q$label),with=F], ql=q$nested, block=block, fill=fill) 
    ## The .MATCH_ID column in 'nested' is used to match nested results to the token_id of the current level (stored under the label column)
    is_req = any(sapply(q$nested, function(x) x$req))
    if (nrow(nested) > 0) {
      if (is_req) {
        selection = merge(selection, nested, by.x=c('doc_id','sentence',q$label), by.y=c('doc_id','sentence','.MATCH_ID'), allow.cartesian=T) 
      } else {
        selection = merge(selection, nested, by.x=c('doc_id','sentence',q$label), by.y=c('doc_id','sentence','.MATCH_ID'), allow.cartesian=T, all.x=T) 
      }
    } else {
      if (is_req) selection = data.table::data.table(.MATCH_ID = numeric(), doc_id=numeric(), sentence=numeric(), .DROP = numeric())
    }
  } 
  data.table::setkeyv(selection, c('doc_id','sentence','.MATCH_ID'))
  selection
}

## merge a list of results where all results are required: req[[1]] AND req[[2]] AND etc.
merge_req <- function(req) {
  out = data.table::data.table()
  if (any(sapply(req, nrow) == 0)) return(out)
  for (dt in req) {
    out = if (nrow(out) == 0) dt else merge(out, dt, by=c('doc_id','sentence','.MATCH_ID'), allow.cartesian=T)
  }
  out
}

## merge a list of results where results are not required: req[[1]] OR req[[2]] OR etc.
merge_not_req <- function(not_req) {
  out = data.table::data.table()
  for (dt in not_req) {
    out = if (nrow(out) == 0) dt else merge(out, dt, by=c('doc_id','sentence','.MATCH_ID'), allow.cartesian=T, all=T)
  }
  out
}

## merge req and not_req results: (req[[1]] AND req[[2]] AND etc.) AND (not_req[[1]] OR not_req[[2]] OR etc).)
merge_req_and_not_req <- function(req, not_req) {
  out = merge_req(req)
  if (nrow(out) > 0) {
    out_not_req = merge_not_req(not_req)
    if (nrow(out_not_req) > 0) {
      out = merge(out, out_not_req, by=c('doc_id','sentence','.MATCH_ID'), allow.cartesian=T, all.x=T)
    }
  }
  out
}

#' Select which tokens to add
#' 
#' Given ids, look for their parents/children (specified in query q) and filter on criteria (specified in query q)
#'
#' @param tokens   The tokenIndex
#' @param ids      A data.table with global ids (doc_id,sentence,token_id). 
#' @param q        a query (possibly nested in another query, or containing nested queries)
#' @param block    A data.table with global ids (doc_id,sentence,token_id) for excluding nodes from the search
select_tokens <- function(tokens, ids, q, block=NULL) {
  .MATCH_ID = NULL ## bindings for data.table
  
  selection = select_token_family(tokens, ids, q, block)
  
  if (!grepl('_FILL', q$label, fixed=T)) {
    selection = subset(selection, select=c('.MATCH_ID', 'doc_id','sentence','token_id'))
    data.table::setnames(selection, 'token_id', q$label)
  } else {
    selection = subset(selection, select=c('.MATCH_ID', 'doc_id','sentence','.FILL_LEVEL','token_id'))
    data.table::setnames(selection, c('token_id','.FILL_LEVEL'), c(q$label, paste0(q$label, '_LEVEL')))
  }
  selection
}

select_token_family <- function(tokens, ids, q, block) {
  if (q$connected) {
    selection = token_family(tokens, ids=ids, level=q$level, depth=q$depth, block=block, replace=T, show_level = T, lookup=q$lookup, g_id=q$g_id)
  } else {
    selection = token_family(tokens, ids=ids, level=q$level, depth=q$depth, block=block, replace=T, show_level = T)
    if (!data.table::haskey(selection)) data.table::setkeyv(selection, c('doc_id','sentence','token_id'))
    selection = filter_tokens(selection, q$lookup, .G_ID = q$g_id)
  }
  selection
}

#' Get the parents or children of a set of ids
#'
#' @param tokens   The tokenIndex
#' @param ids      A data.table with global ids (doc_id,sentence,token_id). 
#' @param level    either 'children' or 'parents'
#' @param depth    How deep to search. eg. children -> grandchildren -> grandgrand etc.
#' @param minimal  If TRUE, only return doc_id, sentence, token_id and parent
#' @param block    A data.table with global ids (doc_id,sentence,token_id) for excluding nodes from the search
#' @param replace  If TRUE, re-use nodes in deep_family() 
#' @param show_level 
#' @param lookup   filter tokens by lookup values. Will be applied at each level (if depth > 1) 
#' @param g_id     filter tokens by id. See lookup
token_family <- function(tokens, ids, level='children', depth=Inf, minimal=F, block=NULL, replace=F, show_level=F, lookup=NULL, g_id=NULL) {
  .MATCH_ID = NULL
  
  if (!replace) block = get_long_ids(ids, block)
  
  if ('.MATCH_ID' %in% colnames(tokens)) tokens[, .MATCH_ID := NULL]
  
  if (level == 'children') {
    id = tokens[list(ids[[1]], ids[[2]], ids[[3]]), on=c('doc_id','sentence','parent'), nomatch=0, allow.cartesian=T]
    id = filter_tokens(id, .BLOCK=block, lookup=lookup, .G_ID = g_id)
    if (minimal) id = subset(id, select = c('doc_id','sentence','token_id','parent'))
    data.table::set(id, j = '.MATCH_ID', value = id[['parent']])
  }
  if (level == 'parents') {
    .NODE = filter_tokens(tokens, .G_ID = ids)
    .NODE = subset(.NODE, select=c('doc_id','sentence','parent','token_id'))
    
    data.table::setnames(.NODE, old='token_id', new='.MATCH_ID')
    id = filter_tokens(tokens, .G_ID = .NODE[,c('doc_id','sentence','parent')], .BLOCK=block)
    id = filter_tokens(id, .G_ID = g_id, lookup=lookup)
    
    if (minimal) id = subset(id, select = c('doc_id','sentence','token_id','parent'))
    id = merge(id, .NODE, by.x=c('doc_id','sentence','token_id'), by.y=c('doc_id','sentence','parent'), allow.cartesian=T)
  }
  if (depth > 1) id = deep_family(tokens, id, level, depth, minimal=minimal, block=block, replace=replace, show_level=show_level, lookup=lookup, g_id=g_id) 
  if (depth <= 1 && show_level) id = cbind(.FILL_LEVEL=as.double(rep(1,nrow(id))), id)
  
  id
}

#' Get the parents or children of a set of ids
#'
#' @param tokens   The tokenIndex
#' @param id       rows in the tokenIndex to use as the ID (for whom to get the family)
#' @param level    either 'children' or 'parents'
#' @param depth    How deep to search. eg. children -> grandchildren -> grandgrand etc.
#' @param minimal  If TRUE, only return doc_id, sentence, token_id and parent
#' @param block    A data.table with global ids (doc_id,sentence,token_id) for excluding nodes from the search
#' @param replace  If TRUE, re-use nodes 
#' @param show_level If TRUE, return a column with the level at which the node was found (e.g., as a parent, grantparent, etc.)
#' @param only_new If TRUE, only return new found family. Otherwise, the id input is included as well.
deep_family <- function(tokens, id, level, depth, minimal=F, block=NULL, replace=F, show_level=F, only_new=F, lookup=NULL, g_id=NULL) {
  id_list = vector('list', 10) ## 10 is just for reserving (more than sufficient) items. R will automatically add more if needed (don't think this actually requires reallocation).
  id_list[[1]] = id
  i = 2
  
  ilc = data.table()  ## infinite loop catcher. Because some parsers have loops...
  safety_depth = max(tokens$token_id) + 1
  while (i <= depth) {
    if (i == safety_depth) {
      warning(sprintf('Safety depth threshold was reached (max token_id), which probably indicates an infinite loop in deep_family(), which shouldnt happen. Please make a GitHub issue if you see this'))
      break
    }
    .NODE = id_list[[i-1]]
    
    if (nrow(ilc) > 0) {
      .NODE = .NODE[!list(ilc$doc_id, ilc$sentence, ilc$token_id, ilc$.MATCH_ID), on=c('doc_id','sentence','token_id','.MATCH_ID')]
    }
    ilc = rbind(ilc, subset(.NODE, select = c('doc_id','sentence','token_id','.MATCH_ID')))
    
    if (!replace) block = get_long_ids(block, .NODE[,c('doc_id','sentence','token_id'), with=F])
    #print(.NODE)
    #.NODE = subset(.NODE, .NODE$token_id %in% unique(.NODE$parent)) ## prevent infinite loops
    
    if (level == 'children') {
      id = filter_tokens(tokens, .G_PARENT = .NODE[,c('doc_id','sentence','token_id')], .BLOCK=block, lookup=lookup, .G_ID=g_id)
      id = merge(id, subset(.NODE, select = c('doc_id','sentence','token_id','.MATCH_ID')), by.x=c('doc_id','sentence','parent'), by.y=c('doc_id','sentence','token_id'), allow.cartesian=T)
      id_list[[i]] = if (minimal) subset(id, select = c('doc_id','sentence','token_id','parent','.MATCH_ID')) else id
    }
    
    if (level == 'parents') {
      id = filter_tokens(tokens, .G_ID = .NODE[,c('doc_id','sentence','parent')], .BLOCK=block)
      id = filter_tokens(id, .G_ID = g_id, lookup=lookup)
      id = merge(id, subset(.NODE, select = c('doc_id','sentence','parent', '.MATCH_ID')), by.x=c('doc_id','sentence','token_id'), by.y=c('doc_id','sentence','parent'), allow.cartesian=T)
      id_list[[i]] = if (minimal) subset(id, select = c('doc_id','sentence','token_id','parent','.MATCH_ID')) else id
   }
    
    #print(nrow(id_list[[i]]))
    if (nrow(id_list[[i]]) == 0) break
    i = i + 1
  }
  
  if (only_new) id_list[[1]] = NULL
  if (show_level) {
    id_list = id_list[!sapply(id_list, is.null)]   ## in older version of data.table R breaks (badly) if idcol is used in rbindlist with NULL values in list
    out = data.table::rbindlist(id_list, use.names = T, idcol = '.FILL_LEVEL')
    out$.FILL_LEVEL = as.double(out$.FILL_LEVEL)
    return(out)
  } else {
    return(data.table::rbindlist(id_list, use.names = T))
  }
}
