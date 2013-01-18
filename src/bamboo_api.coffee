settings =
  URL: "http://bamboo.io"
  DEBUG: true

dbg = ()-> settings.DEBUG
jsonify = (args...)-> JSON.stringify.apply @, args
ensure_jquery = -> throw new Error("jQuery is not available.") unless $?

bamboo_url = (section="datasets", id, name)->
  pieces = [settings.URL, section]
  if id?
    pieces.push id
    pieces.push name if name?
  pieces.join '/'


class Dataset
  constructor: (data) ->
    @extend(data)
    @_ls = {}
    @_reqs = {}

    if @url? and !@id? and @autoload
      @load_from_url()

    @allowed_aggregation = ['max',
                           'min',
                           'mean',
                           'median',
                           'sum',
                           'ratio',
                           'count',
                           'argmax',
                           'newest']

  extend: (obj, override=false) ->
    @[key] = val for key, val of obj when override or !@[key]?

  load_status: (for_what) ->
    @_ls[for_what] = LS.not_started if !@_ls[for_what]?

  load_from_url: (url=false, sync_cb=false) ->
    ensure_jquery()
    @url = url if url
    if !@url?
      throw new Error("Missing URL")
    @_ls.from_url = LS.started
    @_reqs.from_url = $.ajax
      async: !!sync_cb
      data: {url: @url}
      type: 'POST'
      dataType: 'json'
      url: bamboo_url('datasets')
      fail: ()-> @_ls.from_url = LS.failed
      success: (response) =>
        @_ls.from_url = LS.complete
        @extend response
        log "dataset.load_from_url() response", jsonify response if dbg()
        sync_cb.apply(@, arguments) if !!sync_cb
    @

  bamboo_url: () ->
    if !@id?
      throw new Error("Missing dataset ID. " +
                        "Run 'dataset.load_from_url()'.")
    bamboo_url("datasets", @id)

  _run_query: (for_what, url, async, cb, opts={}) ->
    ensure_jquery()
    @_ls[for_what] = LS.started
    opts.async = async unless opts.async?
    opts.url = url
    opts.dataType = 'json' unless opts.dataType?
    opts.success = (response, status, _req) =>
      log "successfully ran #{for_what} query", @ if dbg()
      @_ls[for_what] = LS.complete
      cb.apply(@, [response, status, _req])
    @_reqs[for_what] = $.ajax opts
    @

  query_info: (sync_cb=false) ->
    url = "#{@bamboo_url()}/info"
    @_run_query "info", url, !!sync_cb, (response)->
      @info = response
      sync_cb.apply @, [response, status, _req] if !!sync_cb
      
  summary: (summary_select="all", sync_cb=false)->
    url = "#{@bamboo_url()}/summary?select=#{summary_select}"
    async = !!sync_cb
    summary_tmp_id = "summary_#{summary_select}"
    @_summaries = {} unless @_summaries?
    @_run_query summary_tmp_id, url, async, (r)->
      @summary_result = r if summary_select is "all"
      @_summaries[summary_tmp_id] = r
    if async then @ else @_summaries[summary_tmp_id]

  select: (obj, sync_cb=false) ->
    select_str = jsonify(obj)
    async = !!sync_cb
    url = "#{@bamboo_url()}?select=#{select_str}"
    select_tmp_id = "select_#{select_str}"
    @_selects = {} unless @_selects?
    @_run_query select_tmp_id, url, async, (r)->
      @_selects[select_tmp_id] = r
    if async then @ else @_selects[select_tmp_id]

  query: (obj, sync_cb=false) ->
    query_str = jsonify(obj)
    async = !!sync_cb
    url = "#{@bamboo_url()}?query=#{query_str}"
    query_tmp_id = "query_#{query_str}"
    @_queries = {} unless @_queries?
    @_run_query query_tmp_id, url, async, (r)->
      @_queries[query_tmp_id] = r
    if async then @ else @_queries[query_tmp_id]

  query_dataset: (sync_cb=false) ->
    @_run_query "dataset", bamboo_url("datasets", @id), !!sync_cb, (r)->
      @data = r
      sync_cb.apply @, [response, status, _req] if !!sync_cb

  add_calculation: (name, formula, sync_cb=false) ->
    if @_is_aggregation formula
      throw new Error "Error: this formula indicates it's aggregation
        instead of calculation, please use Dataset.add_aggregation instead"

    calc_id   = _uniqueId("calculation")
    url       = bamboo_url("calculations", @id)
    data =
      name: name
      formula: formula
    success_cb = (response)-> log response.success if dbg()
    opts =
      type: 'POST'
      data: data
    @_run_query "calculation_#{calc_id}", url, false, success_cb, opts

  _is_aggregation: (formula)->
    keyword_sel = @allowed_aggregation.join "|"
    regex_str = "^(#{keyword_sel})\\([^\\)]+\\)$"
    regex = new RegExp(regex_str)
    if formula.match(regex) isnt null
      return true
    return false

  query_calculations: (sync_cb=false) ->
    @_run_query "calculations", bamboo_url("datasets", @id, "calculations"), false, (r)->
      @calculations = r
      sync_cb.apply @, [response, status, _req] if !!sync_cb

  remove_calculation: (name) ->
    url = bamboo_url("calculations", @id)
    data =
      name: name
    success_cb = (response)-> log response.success if dbg()
    opts =
      type: 'DELETE'
      data: data
    @_run_query "delete calculation under name #{name} in dataset #{@id}",
      url, false, success_cb, opts

  add_aggregations:(name, formula, groups=null, sync_cb=false)->
    if @_is_aggregation(formula)
      agg_id = _uniqueId "aggregation"
      url = bamboo_url("calculations", @id)
      data =
        name: name
        formula: formula
      if groups isnt null
        if groups instanceof Array
          data['group'] = groups.join()
        else
          throw new Error "group must be an array"

      success_cb = (response)-> log response.success if dbg()
      opts =
        type: 'POST'
        data: data
      @_run_query "aggregation_#{agg_id}", url, false, success_cb, opts

    else
      throw new Error "ill formated aggregation formula, perhaps you are
        looking for calculation instead of aggregation?"

  query_aggregations: (sync_cb=false) ->
    @_run_query "aggregations", bamboo_url("datasets", @id, "aggregations"), !!sync_cb, (r)->
      @aggregations = r
      sync_cb.apply @, [response, status, _req] if !!sync_cb

  remove_aggregations: (name) ->
    @remove_calculation(name)

  join: (left, right, on_column)->
    ###
    Create a new dataset that is the result of a join, where this
    left_dataset is the lefthand side and *right_dataset* is the
    righthand side and *on* is the column on which to join.
    The column that is joined on must be unique in the righthand side
    and must exist in both datasets.
    ###
    url = bamboo_url("datasets","join")
    data =
      dataset_id: left
      other_dataset_id: right
      on: on_column
    success_cb = (response)-> log response.success if dbg()
    opts =
      type: "POST"
      data: data
    @_run_query "merging datasets #{datasets}", url, false, success_cd, opts
      

  merge:(datasets)->
    ###
    Create a new dataset that is a row-wise merge of those in *datasets*.
    Returns the new merged dataset.
    ###
    if not (datasets instanceof Array)
      throw new Error "datasets for merging must be an array"
    url = bamboo_url('datasets','merge')
    data =
      datasets: datasets
    success_cb = (response)-> log response.success if dbg()
    opts =
      type: "POST"
      data: data
    @_run_query "merging datasets #{datasets}", url, false, success_cd, opts

  update: (rows)->
    ###
    Updates this dataset with the rows given in {column: value} format.
    Any unspecified columns will result in n/a values.
    ###
    if not (rows instanceof Array)
      throw new Error "rows must be an array"
    if rows.length is 0
      throw new Error "rows cannot be empty"
    url = bamboo_url('datasets', @id)
    data =
      update: rows
    success_cb = (response)-> log response.success if dbg()
    opts =
      type: "PUT"
      data: data
    @_run_query "updating dataset #{@id}", url, false, success_cd, opts

  delete: ()->
    complete = false
    $.ajax
      type: "DELETE"
      url: @bamboo_url()
      async: false
      success: -> complete = true
      error: -> complete = false
    complete

dataset_exists = (id)->
  ###
  Not perfect, but this could be a nice way to determine if a dataset exists.
  It returns a boolean value.
  ###
  existence = undefined
  ds = new Dataset({id:id})
  success_cb  = (a,b,c,d,e)-> existence = true
  fail_cb     = -> existence = false
  opts = {
    error: fail_cb
  }
  ds._run_query "existence", "#{ds.bamboo_url()}", false, success_cb, opts
  existence


# load statuses object has key == value. It's an easy-to-reference dictionary
# used only within this file.
LS =
  not_started:    "not_started"
  queued:         "queued"
  started:        "started"
  complete:       "complete"
  failed:         "failed"

@bamboo =
	Dataset: Dataset
	dataset_exists: dataset_exists
	settings: settings

noop = ->
_uniqueIdCount = 0
_uniqueId = (str)->
  "#{str}_#{_uniqueIdCount++}"

###
This is a shortcut for "console.log" that prevents
the call from breaking in browsers where console is
not defined.
###

@log = (args...)->
  console.log.apply console, args if console? and console.log?
