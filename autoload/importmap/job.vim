" async job shim for vim/neovim, synchronous runner, and curl wrapper
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

let s:curl_checked = 0

function! importmap#job#Run(cmd, opts) abort
  if get(g:, 'importmap_sync', 0)
    let l:res = importmap#job#RunSync(a:cmd, get(g:, 'importmap_timeout', 10) * 1000)
    if has_key(a:opts, 'on_done')
      call a:opts.on_done(l:res.code, l:res.lines)
    endif
    return 0
  endif

  if has('nvim')
    let l:state = {'lines': [], 'opts': a:opts}
    let l:job_id = jobstart(a:cmd, {
          \ 'stdout_buffered': v:true,
          \ 'on_stdout': function('s:NvimOnStdout', l:state),
          \ 'on_exit': function('s:NvimOnExit', l:state)
          \ })
    if l:job_id <= 0
      if has_key(a:opts, 'on_done')
        call a:opts.on_done(-1, [])
      endif
    endif
    return l:job_id
  else
    let l:state = {'chunks': [], 'closed': 0, 'exited': 0, 'exit_code': -1, 'opts': a:opts}
    let l:job = job_start(a:cmd, {
          \ 'out_mode': 'raw',
          \ 'out_cb': function('s:VimOutCb', l:state),
          \ 'close_cb': function('s:VimCloseCb', l:state),
          \ 'exit_cb': function('s:VimExitCb', l:state)
          \ })
    if job_status(l:job) ==# 'fail'
      if has_key(a:opts, 'on_done')
        call a:opts.on_done(-1, [])
      endif
    endif
    return l:job
  endif
endfunction

function! s:NvimOnStdout(job_id, data, event) dict abort
  if type(a:data) ==# type([])
    for l:chunk in a:data
      call add(self.lines, l:chunk)
    endfor
  endif
endfunction

function! s:NvimOnExit(job_id, code, event) dict abort
  let l:lines = self.lines
  if !empty(l:lines) && l:lines[-1] ==# ''
    call remove(l:lines, -1)
  endif
  if has_key(self.opts, 'on_done')
    call self.opts.on_done(a:code, l:lines)
  endif
endfunction

function! s:VimOutCb(channel, msg) dict abort
  call add(self.chunks, a:msg)
endfunction

function! s:VimCloseCb(channel) dict abort
  let self.closed = 1
  if self.exited
    call s:VimFlush(self)
  endif
endfunction

function! s:VimExitCb(job, status) dict abort
  let self.exited = 1
  let self.exit_code = a:status
  if self.closed
    call s:VimFlush(self)
  endif
endfunction

function! s:VimFlush(state) abort
  let l:raw = join(a:state.chunks, '')
  let l:lines = split(l:raw, "\r\?\\n", 1)
  if !empty(l:lines) && l:lines[-1] ==# ''
    call remove(l:lines, -1)
  endif
  if has_key(a:state.opts, 'on_done')
    call a:state.opts.on_done(a:state.exit_code, l:lines)
  endif
endfunction

function! importmap#job#RunSync(cmd, timeout_ms) abort
  if has('nvim')
    let l:state = {'lines': [], 'code': -1}
    let l:job_id = jobstart(a:cmd, {
          \ 'stdout_buffered': v:true,
          \ 'on_stdout': function('s:NvimSyncStdout', l:state),
          \ 'on_exit': function('s:NvimSyncExit', l:state)
          \ })
    if l:job_id <= 0
      return {'code': -1, 'lines': []}
    endif
    let l:res = jobwait([l:job_id], a:timeout_ms)
    if !empty(l:res) && l:res[0] == -1
      try
        call jobstop(l:job_id)
      catch
      endtry
      return {'code': -1, 'lines': l:state.lines}
    endif
    return {'code': l:state.code, 'lines': l:state.lines}
  else
    let l:escaped = join(map(copy(a:cmd), 'shellescape(v:val)'), ' ')
    let l:out = system(l:escaped)
    let l:code = v:shell_error
    let l:lines = split(l:out, "\r\?\\n", 1)
    if !empty(l:lines) && l:lines[-1] ==# ''
      call remove(l:lines, -1)
    endif
    return {'code': l:code, 'lines': l:lines}
  endif
endfunction

function! s:NvimSyncStdout(job_id, data, event) dict abort
  if type(a:data) ==# type([])
    for l:chunk in a:data
      call add(self.lines, l:chunk)
    endfor
  endif
endfunction

function! s:NvimSyncExit(job_id, code, event) dict abort
  let self.code = a:code
  if !empty(self.lines) && self.lines[-1] ==# ''
    call remove(self.lines, -1)
  endif
endfunction

function! importmap#job#GetJson(url, headers, opts) abort
  if !s:curl_checked && !executable(g:importmap_curl)
    call importmap#util#Error('curl not found (set g:importmap_curl)')
    if has_key(a:opts, 'on_done')
      call a:opts.on_done(v:null)
    endif
    return 0
  endif
  let s:curl_checked = 1

  let l:cmd = [g:importmap_curl, '-sfL', '--max-time', string(g:importmap_timeout), '-H', 'Accept: application/vnd.npm.install-v1+json']
  if type(a:headers) ==# type([])
    for l:hdr in a:headers
      call extend(l:cmd, ['-H', l:hdr])
    endfor
  elseif type(a:headers) ==# type({})
    for [l:k, l:v] in items(a:headers)
      call extend(l:cmd, ['-H', l:k . ': ' . l:v])
    endfor
  endif
  call add(l:cmd, a:url)

  call importmap#util#Log('GetJson: ' . a:url)
  return importmap#job#Run(l:cmd, {'on_done': function('s:OnGetJsonDone', [a:opts])})
endfunction

function! s:OnGetJsonDone(opts, exit_code, lines) abort
  if a:exit_code != 0
    if has_key(a:opts, 'on_done')
      call a:opts.on_done(v:null)
    endif
    return
  endif
  let l:raw = join(a:lines, "\n")
  try
    let l:decoded = json_decode(l:raw)
    if has_key(a:opts, 'on_done')
      call a:opts.on_done(l:decoded)
    endif

  catch
    if has_key(a:opts, 'on_done')
      call a:opts.on_done(v:null)
    endif
  endtry
endfunction

" Countdown latch for bounded parallel async jobs
function! importmap#job#Latch(items, max_concurrency, fn_worker, on_all_done) abort
  let l:latch = {
        \ 'items': copy(a:items),
        \ 'max': a:max_concurrency > 0 ? a:max_concurrency : 8,
        \ 'fn': a:fn_worker,
        \ 'on_all_done': a:on_all_done,
        \ 'remaining': len(a:items),
        \ 'results': {},
        \ 'in_flight': 0,
        \ 'idx': 0
        \ }
  if l:latch.remaining == 0
    call call(l:latch.on_all_done, [l:latch.results])
    return l:latch
  endif
  call s:LatchStep(l:latch)
  return l:latch
endfunction

function! s:LatchStep(latch) abort
  while a:latch.in_flight < a:latch.max && a:latch.idx < len(a:latch.items)
    let l:item = a:latch.items[a:latch.idx]
    let a:latch.idx += 1
    let a:latch.in_flight += 1
    call call(a:latch.fn, [l:item, function('s:LatchOnItemDone', [a:latch, l:item])])
  endwhile
endfunction

function! s:LatchOnItemDone(latch, item, result) abort
  let l:key = type(a:item) ==# type({}) && has_key(a:item, 'name') ? a:item.name : (type(a:item) ==# type('') ? a:item : string(a:item))
  let a:latch.results[l:key] = a:result

  let a:latch.in_flight -= 1

  let a:latch.remaining -= 1
  if a:latch.remaining <= 0
    call call(a:latch.on_all_done, [a:latch.results])
  else
    call s:LatchStep(a:latch)
  endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
