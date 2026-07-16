" deterministic import map JSON serialization
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

function! importmap#mapfile#CompareKeys(a, b) abort
  let l:base_a = substitute(tolower(a:a), '/$', '', '')
  let l:base_b = substitute(tolower(a:b), '/$', '', '')
  if l:base_a !=# l:base_b
    return l:base_a <# l:base_b ? -1 : 1
  endif
  let l:has_slash_a = a:a =~# '/$' ? 1 : 0
  let l:has_slash_b = a:b =~# '/$' ? 1 : 0
  if l:has_slash_a != l:has_slash_b
    return l:has_slash_a < l:has_slash_b ? -1 : 1
  endif
  if a:a !=# a:b
    return a:a <# a:b ? -1 : 1
  endif
  return 0
endfunction

function! s:SortTopLevelKeys(dict) abort
  let l:priority = ['imports', 'scopes', 'integrity']
  let l:ordered = []
  for l:p in l:priority
    if has_key(a:dict, l:p)
      call add(l:ordered, l:p)
    endif
  endfor
  let l:others = []
  for l:k in keys(a:dict)
    if index(l:priority, l:k) == -1
      call add(l:others, l:k)
    endif
  endfor
  call sort(l:others, 'importmap#mapfile#CompareKeys')
  return extend(l:ordered, l:others)
endfunction

function! s:EncodeStr(str) abort
  " escape < so a value containing </script> cannot terminate the block
  return substitute(json_encode(a:str), '<', '\\u003c', 'g')
endfunction


function! s:SerializeValue(val, indent_str, inner_ind, is_top) abort
  if type(a:val) ==# type({})
    if empty(a:val)
      return [a:indent_str . '{}']
    endif
    let l:keys = a:is_top ? s:SortTopLevelKeys(a:val) : sort(copy(keys(a:val)), 'importmap#mapfile#CompareKeys')
    let l:lines = [a:indent_str . '{']
    let l:num_keys = len(l:keys)
    let l:i = 0
    while l:i < l:num_keys
      let l:k = l:keys[l:i]
      let l:v = a:val[l:k]
      let l:sub_lines = s:SerializeValue(l:v, a:indent_str . a:inner_ind, a:inner_ind, 0)
      let l:comma = (l:i < l:num_keys - 1) ? ',' : ''
      let l:first_sub = substitute(l:sub_lines[0], '^\s*', '', '')
      if len(l:sub_lines) == 1
        call add(l:lines, a:indent_str . a:inner_ind . s:EncodeStr(l:k) . ': ' . l:first_sub . l:comma)
      else
        call add(l:lines, a:indent_str . a:inner_ind . s:EncodeStr(l:k) . ': ' . l:first_sub)
        for l:line in l:sub_lines[1 : -2]
          call add(l:lines, l:line)
        endfor
        call add(l:lines, l:sub_lines[-1] . l:comma)
      endif
      let l:i += 1
    endwhile
    call add(l:lines, a:indent_str . '}')
    return l:lines

  elseif type(a:val) ==# type([])
    if empty(a:val)
      return [a:indent_str . '[]']
    endif
    let l:lines = [a:indent_str . '[']
    let l:num_items = len(a:val)
    let l:i = 0
    while l:i < l:num_items
      let l:item = a:val[l:i]
      let l:sub_lines = s:SerializeValue(l:item, a:indent_str . a:inner_ind, a:inner_ind, 0)
      let l:comma = (l:i < l:num_items - 1) ? ',' : ''
      if len(l:sub_lines) == 1
        call add(l:lines, l:sub_lines[0] . l:comma)
      else
        for l:line in l:sub_lines[0 : -2]
          call add(l:lines, l:line)
        endfor
        call add(l:lines, l:sub_lines[-1] . l:comma)
      endif
      let l:i += 1
    endwhile
    call add(l:lines, a:indent_str . ']')
    return l:lines

  elseif type(a:val) ==# type('')
    return [a:indent_str . s:EncodeStr(a:val)]
  else
    return [a:indent_str . json_encode(a:val)]
  endif
endfunction


function! importmap#mapfile#Serialize(map_dict, base_indent) abort
  let l:base_ind_str = type(a:base_indent) ==# type(0) ? repeat(' ', a:base_indent) : (type(a:base_indent) ==# type('') ? a:base_indent : '')
  let l:inner_ind = repeat(' ', get(g:, 'importmap_indent', 2))
  let l:lines = s:SerializeValue(a:map_dict, l:base_ind_str, l:inner_ind, 1)
  return l:lines
endfunction

function! s:CompactValue(val, is_top) abort
  if type(a:val) ==# type({})
    let l:keys = a:is_top ? s:SortTopLevelKeys(a:val) : sort(copy(keys(a:val)), 'importmap#mapfile#CompareKeys')
    let l:parts = []
    for l:k in l:keys
      call add(l:parts, s:EncodeStr(l:k) . ':' . s:CompactValue(a:val[l:k], 0))
    endfor
    return '{' . join(l:parts, ',') . '}'
  elseif type(a:val) ==# type([])
    return '[' . join(map(copy(a:val), 's:CompactValue(v:val, 0)'), ',') . ']'
  elseif type(a:val) ==# type('')
    return s:EncodeStr(a:val)
  else
    return json_encode(a:val)
  endif
endfunction

" single-line form, used when the block being rewritten sits on one line
function! importmap#mapfile#SerializeCompact(map_dict) abort
  return s:CompactValue(a:map_dict, 1)
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo

