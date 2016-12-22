" The MIT License (MIT)
"
" Copyright (c) 2016 Evgeni Kolev

" Permission is hereby granted, free of charge, to any person obtaining a copy
" of this software and associated documentation files (the "Software"), to deal
" in the Software without restriction, including without limitation the rights
" to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
" copies of the Software, and to permit persons to whom the Software is
" furnished to do so, subject to the following conditions:

" The above copyright notice and this permission notice shall be included in all
" copies or substantial portions of the Software.

" THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
" IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
" FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
" AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
" LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
" OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
" SOFTWARE.

let s:jobs = {}
let s:timers = {}

" withtout this patch vim check every 10 seconds for finished jobs so timer
" are used to force vim (with job_status()) to check more frequently
let s:should_use_timers = !has("patch-8.0.0055")

" TODO try to remove s:close_callback -- chan_id should be replaced by some other id

fun! AmakeRunning()
   if len(keys(s:jobs)) == 0
      return ''
   elseif len(keys(s:jobs)) == 1
      return ':' . s:jobs[keys(s:jobs)[0]].autocmd
   else
      return 'multiple'
   endif
endfun

fun! s:l(msg)
  :call writefile([a:msg], "/tmp/event.log", "a")
endfun

fun! s:error (msg)
    echohl ErrorMsg | echo "amake: " . a:msg | echohl None
    return ''
endfun


fun! amake#start(bang, makeprg_name, errorformat_name, autocmd, args) abort
  let makeprg = eval("&" . a:makeprg_name)
  let errorformat = eval("&" . a:errorformat_name)
  if empty(makeprg)
    return s:error("&" . a:makeprg_name . " is empty")
  endif
  call s:start(a:bang, makeprg, errorformat, a:autocmd, a:args)
endfun

fun! s:expand(cmd, args) abort
  " expand args
  let cmd = substitute(a:cmd, '\$\*', a:args, 'g')

  " from tpope's vim-dispatch https://github.com/tpope/vim-dispatch
  let s:flags = '<\=\%(:[p8~.htre]\|:g\=s\(.\).\{-\}\1.\{-\}\1\)*'
  let s:expandable = '\\*\%(<\w\+>\|%\|#\d*\)' . s:flags
  let cmd = substitute(cmd, s:expandable, '\=expand(submatch(0))', 'g')

  " trim whitespace
  return substitute(cmd, '^\s*\|\s*$', '', 'g')
endfun

fun! s:start(bang, makeprg, errorformat, autocmd, args) abort
  if len(keys(s:jobs)) > 0
    return s:error("previous job still running")
  endif
  let cmd = s:expand(a:makeprg, a:args)
  if &autowrite || &autowriteall
    silent! wall
  endif

  cclose
  let output_file = tempname()
  let job_options = {
        \ 'close_cb': function('s:close_callback'),
        \ 'exit_cb' : function('s:exit_callback'),
        \ 'out_io'  : 'file',
        \ 'out_name': output_file,
        \ 'err_io'  : 'out',
        \ 'in_io'   : 'null',
        \ 'out_mode': 'nl',
        \ 'err_mode': 'nl'}
  let job = job_start(cmd, job_options)

  if job_status(job) ==# 'fail'
    return s:error( "failed staring " . cmd )
  endif

  call s:l('job "' . cmd . '" started')
  echo "Running: " . cmd

  let channel = job_getchannel(job)
  let chan_id = string(ch_info(channel).id)
  if empty(chan_id)
    return s:error( "failed staring " . cmd )
  endif

  let s:jobs[chan_id] = { 'output_file': output_file, 'cmd': cmd, 'channel': channel,
                         \'errorformat': a:errorformat, 'bang': a:bang, 'autocmd': a:autocmd }

  let intervals = [25, 50, 100, 300, 600, 1000, 1500, 2000, 3000, 5000]
  if s:should_use_timers
     let timer_id = timer_start(remove(intervals, 0), function('s:check_status'))
     let s:timers[timer_id] = { 'chan_id': chan_id, 'intervals': intervals }
  endif

  return chan_id
endfun

fun! s:exit_callback(job, exit_status)
  call s:l('exit callback, status: ' . a:exit_status)
  let chan_id = s:channel_id(a:job)
  if empty(chan_id)
    return s:error("failed getting channel of job")
  endif

  let job = remove(s:jobs, chan_id)
  call s:open_qf(a:exit_status, job)
endfun

fun! s:open_qf(exit_status, job) abort
  let was_in_qf = &buftype ==# 'quickfix'

  let save = &errorformat
  let &errorformat = a:job.errorformat

  execute "silent doautocmd QuickFixCmdPre " . a:job.autocmd
  let cfile = a:job.bang ? 'cgetfile' : 'cfile'
  execute 'noautocmd ' . cfile . ' ' . fnameescape(a:job.output_file)
  execute "silent doautocmd QuickFixCmdPost " . a:job.autocmd

  exec "cgetfile " . a:job.output_file
  let &errorformat = save

  call delete(a:job.output_file)

  if (a:exit_status)
     botright copen
  endif

  let is_in_qf = &buftype ==# 'quickfix'
  if was_in_qf != is_in_qf
    wincmd p
  endif

  call setqflist([], 'r', {'title': a:job.cmd})
  silent redraw!
  echo (a:exit_status ? "Failure: " : "Success: ") . a:job.cmd
endfun

fun! s:close_callback(channel)
  return ''
endfun

fun! s:channel_id(job)
  if job_status(a:job) ==# 'fail'
    return ''
  endif

  let channel = job_getchannel(a:job)
  if string(channel) ==# 'channel fail'
    return ''
  endif

  let channel_info = ch_info(channel)
  return string(channel_info.id)
endfun

if !s:should_use_timers
   finish
endif

fun! s:check_status(timer_id) abort
  let timer = remove(s:timers,a:timer_id)
  let chan_id = timer.chan_id

  call s:l('timer ' . a:timer_id)

  if !has_key(s:jobs, chan_id)
    call s:l('1')
    return
  endif
  let channel = s:jobs[chan_id].channel

  " force vim to check if the job is running
  let status = job_status(ch_getjob(channel))
  if (status != "run")
    call s:l('timer: job no running anymore')
    return
  endif

  if empty(timer.intervals)
    call s:l('timer: no more intervals')
    return
  endif

  " start a new timer
  let new_timer_id = timer_start(remove(timer.intervals, 0), function('s:check_status'))
  call s:l('timer: new timer started' . new_timer_id)
  let s:timers[new_timer_id] = timer
endfun

