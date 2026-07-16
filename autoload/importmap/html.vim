" locate, parse, and rewrite the importmap block in HTML or JSON files
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

" a whole <script ...> opening tag, tolerating > inside quoted attributes
let s:open_tag_pat = '\c<script\%(\_s\%(\_[^>"'']\|"\_[^"]*"\|''\_[^'']*''\)*\)\?>'
let s:link_tag_pat = '\c<link\%(\_s\%(\_[^>"'']\|"\_[^"]*"\|''\_[^'']*''\)*\)\?>'

function! importmap#html#LocateTarget() abort
  if exists('b:importmap_target') && !empty(b:importmap_target)
    return resolve(fnamemodify(b:importmap_target, ':p'))
  endif
  if !empty(g:importmap_target)
    return resolve(fnamemodify(g:importmap_target, ':p'))
  endif

  let l:curr = resolve(expand('%:p'))
  if !empty(l:curr) && (expand('%:e') =~? '^\(html\|htm\)$' || &filetype ==# 'html')
    if filereadable(l:curr) || bufloaded(bufnr(l:curr))
      return l:curr
    endif
  endif

  let l:root = importmap#util#FindRoot()
  for l:cand in g:importmap_html_candidates
    let l:path = l:root . '/' . l:cand
    if filereadable(l:path) || (bufnr(l:path) != -1 && bufloaded(bufnr(l:path)))
      return resolve(fnamemodify(l:path, ':p'))
    endif
  endfor

  if !empty(l:curr) && (expand('%:e') =~? 'json$' || &filetype ==# 'json')
    if filereadable(l:curr) || bufloaded(bufnr(l:curr))
      return l:curr
    endif
  endif

  throw 'importmap.vim: no target HTML found (set g:importmap_target or open your index.html)'
endfunction

" 1-based line number of the byte offset in the joined string
function! s:LineOf(str, off) abort
  return count(strpart(a:str, 0, a:off), "\n") + 1
endfunction

" byte offset of the start of the 1-based line number
function! s:LineStart(lines, lnum) abort
  let l:off = 0
  let l:i = 0
  while l:i < a:lnum - 1
    let l:off += strlen(a:lines[l:i]) + 1
    let l:i += 1
  endwhile
  return l:off
endfunction

function! s:CommentRanges(str) abort
  let l:ranges = []
  let l:pos = 0
  while 1
    let l:s = match(a:str, '<!--', l:pos)
    if l:s == -1
      break
    endif
    let l:e = matchend(a:str, '-->', l:s + 4)
    if l:e == -1
      call add(l:ranges, [l:s, strlen(a:str)])
      break
    endif
    call add(l:ranges, [l:s, l:e])
    let l:pos = l:e
  endwhile
  return l:ranges
endfunction

function! s:InComment(ranges, off) abort
  for l:r in a:ranges
    if a:off >= l:r[0] && a:off < l:r[1]
      return 1
    endif
  endfor
  return 0
endfunction

" read lines exactly as stored: strips CR and the trailing newline, but
" remembers both so a write can put them back
function! s:ReadLines(path, bufnr, loaded) abort
  if a:loaded
    return {'lines': getbufline(a:bufnr, 1, '$'), 'crlf': 0, 'trailing_nl': 1}
  endif
  let l:lines = readfile(a:path, 'b')
  let l:trailing_nl = !empty(l:lines) && l:lines[-1] ==# ''
  if l:trailing_nl
    call remove(l:lines, -1)
  endif
  let l:crlf = !empty(l:lines) && l:lines[0] =~# '\r$'
  call map(l:lines, 'substitute(v:val, ''\r$'', '''', '''')')
  return {'lines': l:lines, 'crlf': l:crlf, 'trailing_nl': l:trailing_nl}
endfunction

function! importmap#html#ReadMap(target_info) abort
  let l:path = type(a:target_info) ==# type({}) ? a:target_info.path : a:target_info
  let l:bufnr = bufnr(l:path)
  let l:loaded = (l:bufnr != -1 && bufloaded(l:bufnr))
  let l:read = s:ReadLines(l:path, l:bufnr, l:loaded)
  let l:raw_lines = l:read.lines
  let l:crlf = l:read.crlf
  let l:trailing_nl = l:read.trailing_nl
  let l:is_json = l:path =~? '\.json$'

  let l:base = {'raw_lines': l:raw_lines, 'path': l:path, 'crlf': l:crlf, 'trailing_nl': l:trailing_nl}

  if l:is_json
    let l:json_str = join(l:raw_lines, "\n")
    if empty(trim(l:json_str))
      let l:parsed = {'imports': {}}
    else
      try
        let l:parsed = json_decode(l:json_str)
      catch
        throw 'importmap.vim: malformed JSON in ' . l:path . ' (' . v:exception . ')'
      endtry
    endif
    return extend(l:base, {'parsed': l:parsed, 'map': l:parsed, 'start_line': 1, 'end_line': max([1, len(l:raw_lines)]), 'indent': '', 'is_json_mode': 1, 'found': 1})
  endif

  let l:s = join(l:raw_lines, "\n")
  let l:comments = s:CommentRanges(l:s)
  let l:found = 0
  let l:tag = {}
  let l:pos = 0
  while 1
    let l:m = matchstrpos(l:s, s:open_tag_pat, l:pos)
    if l:m[1] == -1
      break
    endif
    let l:pos = l:m[2]
    if s:InComment(l:comments, l:m[1])
      continue
    endif
    if l:m[0] !~? 'type\s*=\s*["'']\?importmap["'']\?'
      continue
    endif
    if l:found
      call importmap#util#Warn('multiple importmap blocks detected; operating on the first one')
      break
    endif
    if l:m[0] =~? '\ssrc\s*='
      throw 'importmap.vim: external import map with src= attribute cannot be edited inline'
    endif
    let l:close_start = match(l:s, '\c</script\s*>', l:m[2])
    if l:close_start == -1
      throw 'importmap.vim: unclosed <script type="importmap"> tag starting at line ' . s:LineOf(l:s, l:m[1])
    endif
    let l:found = 1
    let l:tag = {'open_start': l:m[1], 'open_end': l:m[2], 'open_tag': l:m[0], 'close_start': l:close_start, 'close_end': matchend(l:s, '\c</script\s*>', l:m[2])}
    let l:pos = l:tag.close_end
  endwhile

  if !l:found
    return extend(l:base, {'parsed': {'imports': {}}, 'map': {'imports': {}}, 'start_line': -1, 'end_line': -1, 'indent': '', 'is_json_mode': 0, 'found': 0})
  endif

  let l:json_str = strpart(l:s, l:tag.open_end, l:tag.close_start - l:tag.open_end)
  let l:start_line = s:LineOf(l:s, l:tag.open_start)
  let l:end_line = s:LineOf(l:s, l:tag.close_end - 1)
  let l:indent = matchstr(l:raw_lines[l:start_line - 1], '^\s*')

  if empty(trim(l:json_str))
    let l:parsed = {'imports': {}}
  else
    try
      let l:parsed = json_decode(l:json_str)
    catch
      throw 'importmap.vim: malformed JSON inside <script type="importmap"> starting at line ' . l:start_line . ' (' . v:exception . ')'
    endtry
  endif

  return extend(l:base, extend(l:tag, {'parsed': l:parsed, 'map': l:parsed, 'start_line': l:start_line, 'end_line': l:end_line, 'indent': l:indent, 'is_json_mode': 0, 'found': 1, 'inline': l:start_line == l:end_line}))
endfunction

" apply the joined result string to the buffer (patching only the changed
" region) or to disk (restoring CR and the trailing newline)
function! s:WriteOut(new_s, path, bufnr, loaded, meta, start_line, end_line) abort
  let l:out_lines = split(a:new_s, "\n", 1)
  call importmap#util#Log('write: ' . a:path)
  if a:loaded
    let l:delta = len(l:out_lines) - len(a:meta.raw_lines)
    let l:new_end = a:end_line + l:delta
    let l:region = a:start_line <= l:new_end ? l:out_lines[a:start_line - 1 : l:new_end - 1] : []
    let l:old_count = a:end_line - a:start_line + 1
    let l:new_count = len(l:region)
    if l:old_count == 0
      call appendbufline(a:bufnr, a:start_line - 1, l:region)
    elseif l:new_count == l:old_count
      call setbufline(a:bufnr, a:start_line, l:region)
    elseif l:new_count < l:old_count
      call deletebufline(a:bufnr, a:start_line + l:new_count, a:end_line)
      if l:new_count > 0
        call setbufline(a:bufnr, a:start_line, l:region)
      endif
    else
      call setbufline(a:bufnr, a:start_line, l:region[: l:old_count - 1])
      call appendbufline(a:bufnr, a:end_line, l:region[l:old_count :])
    endif
  else
    let l:write = copy(l:out_lines)
    if a:meta.crlf
      call map(l:write, 'v:val . nr2char(13)')
    endif
    if a:meta.trailing_nl
      call add(l:write, '')
    endif
    call writefile(l:write, a:path, 'b')
  endif
endfunction

function! importmap#html#WriteMap(target_info, map_dict, ...) abort
  let l:path = type(a:target_info) ==# type({}) ? a:target_info.path : a:target_info
  let l:meta = a:0 > 0 && type(a:1) ==# type({}) && has_key(a:1, 'raw_lines') ? a:1 : importmap#html#ReadMap(l:path)
  let l:bufnr = bufnr(l:path)
  let l:loaded = (l:bufnr != -1 && bufloaded(l:bufnr))
  let l:raw_lines = l:meta.raw_lines
  let l:s = join(l:raw_lines, "\n")

  if get(l:meta, 'is_json_mode', l:path =~? '\.json$')
    let l:new_s = join(importmap#mapfile#Serialize(a:map_dict, ''), "\n")
    call s:WriteOut(l:new_s, l:path, l:bufnr, l:loaded, l:meta, 1, max([1, len(l:raw_lines)]))
    return
  endif

  if get(l:meta, 'found', 0)
    let l:base_ind = l:meta.indent
    if get(l:meta, 'inline', 0)
      let l:block = l:meta.open_tag . importmap#mapfile#SerializeCompact(a:map_dict) . '</script>'
    else
      let l:block = l:meta.open_tag . "\n" . join(importmap#mapfile#Serialize(a:map_dict, l:base_ind), "\n") . "\n" . l:base_ind . '</script>'
    endif
    let l:new_s = strpart(l:s, 0, l:meta.open_start) . l:block . strpart(l:s, l:meta.close_end)
    call s:WriteOut(l:new_s, l:path, l:bufnr, l:loaded, l:meta, l:meta.start_line, l:meta.end_line)
    return
  endif

  " no block yet: insert before the first module script or modulepreload
  " link, else before </head>, else just after <head>
  let l:comments = s:CommentRanges(l:s)
  let l:anchor = s:FindInsertAnchor(l:s, l:comments)
  if empty(l:anchor)
    throw 'importmap.vim: cannot insert importmap block (no <head> or module script found in HTML)'
  endif

  let l:lnum = s:LineOf(l:s, l:anchor.off)
  let l:line = l:raw_lines[l:lnum - 1]
  let l:line_start = s:LineStart(l:raw_lines, l:lnum)
  let l:col = l:anchor.off - l:line_start

  if l:anchor.where ==# 'before'
    let l:base_ind = matchstr(l:line, '^\s*')
    if empty(l:base_ind) && l:lnum > 1
      let l:base_ind = matchstr(l:raw_lines[l:lnum - 2], '^\s*')
    endif
    if strpart(l:line, 0, l:col) =~# '^\s*$'
      " the anchor starts its line: insert whole lines above it
      let l:block = join(s:BlockLines(a:map_dict, l:base_ind), "\n") . "\n"
      let l:new_s = strpart(l:s, 0, l:line_start) . l:block . strpart(l:s, l:line_start)
      call s:WriteOut(l:new_s, l:path, l:bufnr, l:loaded, l:meta, l:lnum, l:lnum - 1)
    else
      let l:block = '<script type="importmap">' . importmap#mapfile#SerializeCompact(a:map_dict) . '</script>'
      let l:new_s = strpart(l:s, 0, l:anchor.off) . l:block . strpart(l:s, l:anchor.off)
      call s:WriteOut(l:new_s, l:path, l:bufnr, l:loaded, l:meta, l:lnum, l:lnum)
    endif
  else
    " after the <head> opening tag
    let l:base_ind = matchstr(l:line, '^\s*') . repeat(' ', g:importmap_indent)
    if strpart(l:line, l:col) =~# '^\s*$'
      let l:block = "\n" . join(s:BlockLines(a:map_dict, l:base_ind), "\n")
      let l:line_end = l:line_start + strlen(l:line)
      let l:new_s = strpart(l:s, 0, l:line_end) . l:block . strpart(l:s, l:line_end)
      call s:WriteOut(l:new_s, l:path, l:bufnr, l:loaded, l:meta, l:lnum + 1, l:lnum)
    else
      let l:block = '<script type="importmap">' . importmap#mapfile#SerializeCompact(a:map_dict) . '</script>'
      let l:new_s = strpart(l:s, 0, l:anchor.off) . l:block . strpart(l:s, l:anchor.off)
      call s:WriteOut(l:new_s, l:path, l:bufnr, l:loaded, l:meta, l:lnum, l:lnum)
    endif
  endif
endfunction

function! s:BlockLines(map_dict, base_ind) abort
  return [a:base_ind . '<script type="importmap">'] + importmap#mapfile#Serialize(a:map_dict, a:base_ind) + [a:base_ind . '</script>']
endfunction

function! s:FindInsertAnchor(str, comments) abort
  " first module script or modulepreload link, whichever comes first
  let l:best = -1
  let l:pos = 0
  while 1
    let l:m = matchstrpos(a:str, s:open_tag_pat, l:pos)
    if l:m[1] == -1
      break
    endif
    let l:pos = l:m[2]
    if !s:InComment(a:comments, l:m[1]) && l:m[0] =~? 'type\s*=\s*["'']\?module["'']\?'
      let l:best = l:m[1]
      break
    endif
  endwhile
  let l:pos = 0
  while 1
    let l:m = matchstrpos(a:str, s:link_tag_pat, l:pos)
    if l:m[1] == -1
      break
    endif
    let l:pos = l:m[2]
    if !s:InComment(a:comments, l:m[1]) && l:m[0] =~? 'rel\s*=\s*["'']\?modulepreload["'']\?'
      if l:best == -1 || l:m[1] < l:best
        let l:best = l:m[1]
      endif
      break
    endif
  endwhile
  if l:best != -1
    return {'off': l:best, 'where': 'before'}
  endif

  let l:pos = 0
  while 1
    let l:off = match(a:str, '\c</head\s*>', l:pos)
    if l:off == -1
      break
    endif
    if !s:InComment(a:comments, l:off)
      return {'off': l:off, 'where': 'before'}
    endif
    let l:pos = matchend(a:str, '\c</head\s*>', l:pos)
  endwhile

  let l:pos = 0
  while 1
    let l:m = matchstrpos(a:str, '\c<head\%(\_s\%(\_[^>"'']\|"\_[^"]*"\|''\_[^'']*''\)*\)\?>', l:pos)
    if l:m[1] == -1
      break
    endif
    if !s:InComment(a:comments, l:m[1])
      return {'off': l:m[2], 'where': 'after'}
    endif
    let l:pos = l:m[2]
  endwhile

  return {}
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
