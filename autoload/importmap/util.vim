" root detection, logging, caching, messaging
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

function! importmap#util#FindRoot() abort
  let l:start = expand('%:p:h')
  if empty(l:start) || !isdirectory(l:start)
    let l:start = getcwd()
  endif
  let l:dir = fnamemodify(l:start, ':p:s?/$??')
  while 1
    for l:marker in g:importmap_root_markers
      let l:check = l:dir . '/' . l:marker
      if filereadable(l:check) || isdirectory(l:check)
        return l:dir
      endif
    endfor
    let l:parent = fnamemodify(l:dir, ':h')
    if l:parent ==# l:dir || empty(l:parent)
      break
    endif
    let l:dir = l:parent
  endwhile
  return fnamemodify(l:start, ':p:s?/$??')
endfunction

function! importmap#util#CacheDir() abort
  if !empty(get(g:, 'importmap_cache_dir', ''))
    let l:dir = expand(g:importmap_cache_dir)
  else
    if has('nvim')
      let l:base = stdpath('cache')
    elseif !empty($XDG_CACHE_HOME)
      let l:base = $XDG_CACHE_HOME
    else
      let l:base = expand('~/.cache')
    endif
    let l:dir = l:base . '/importmap.vim'
  endif
  if !isdirectory(l:dir)
    call mkdir(l:dir, 'p')
  endif
  return l:dir
endfunction

let s:log_warned = 0

function! importmap#util#Log(msg) abort
  if exists('g:importmap_log') && !empty(g:importmap_log)
    try
      let l:dir = fnamemodify(g:importmap_log, ':p:h')
      if !isdirectory(l:dir)
        call mkdir(l:dir, 'p')
      endif
      let l:line = strftime('%Y-%m-%d %H:%M:%S') . ' ' . a:msg
      call writefile([l:line], g:importmap_log, 'a')
    catch
      if !s:log_warned
        let s:log_warned = 1
        call importmap#util#Warn('failed to write to log file ' . g:importmap_log . ' (' . v:exception . ')')
      endif
    endtry
  endif
endfunction

function! importmap#util#Error(msg) abort
  echohl ErrorMsg
  echomsg 'importmap.vim: ' . a:msg
  echohl None
endfunction

function! importmap#util#Warn(msg) abort
  echohl WarningMsg
  echomsg 'importmap.vim: ' . a:msg
  echohl None
endfunction

function! importmap#util#Info(msg) abort
  echomsg 'importmap.vim: ' . a:msg
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
