command! -nargs=* M call AMake(<q-args>)

" TODO try to remove CloseCallback
" TODO ExitCallback should check status

let s:timers = {}
let s:timers_inv = {}
let s:job_commands = {}
let s:job_output_files = {}

let s:jobs = {}

fun! s:l(msg)
  :call writefile([a:msg], "/tmp/event.log", "a")
endfun

fun! s:error (msg)
    echohl ErrorMsg | "amake: " . a:msg| echohl None
    return ''
endfun

" get timer by channel id
" get comamnd line by channel id
" get output file by channel id

" get channel id by timer id

fun! AMake(args) abort
  if empty(&makeprg)
    echohl ErrorMsg | "amake: &makeprg is empty" | echohl None
    return
  endif
  cclose
  call Start(Expand(&makeprg, a:args))
endfun

fun! Expand(cmd, args) abort
  let cmd = substitute(a:cmd, '\$\*', a:args, 'g')
  " from tpope's vim-dispatch https://github.com/tpope/vim-dispatch
  let s:flags = '<\=\%(:[p8~.htre]\|:g\=s\(.\).\{-\}\1.\{-\}\1\)*'
  let s:expandable = '\\*\%(<\w\+>\|%\|#\d*\)' . s:flags
  return substitute(cmd, s:expandable, '\=expand(submatch(0))', 'g')
endfun

function! Start(cmd) abort
  let output_file = tempname()
  " TODO try to remove CloseCallback
  let job_options = {
        \ 'close_cb': function('CloseCallback'),
        \ 'exit_cb' : function('ExitCallback'),
        \ 'out_io'  : 'file',
        \ 'out_name': output_file,
        \ 'err_io'  : 'out',
        \ 'in_io'   : 'null',
        \ 'out_mode': 'nl',
        \ 'err_mode': 'nl'}
  let job = job_start(a:cmd, job_options)

  if job_status(job) ==# 'fail'
    return s:error( "failed staring " . a:cmd )
  endif

  call s:l('job started')

  let channel = job_getchannel(job)
  let chan_id = string(ch_info(channel).id)
  if empty(chan_id)
    return s:error( "failed staring " . a:cmd )
  endif

  let s:jobs[chan_id] = { 'output_file': output_file, 'cmd': a:cmd, 'channel': channel }

  let intervals = [25, 50, 100, 300, 600, 1000, 3000, 5000]
  let timer_id = timer_start(remove(intervals, 0), 'CheckStatus')
  let s:timers[timer_id] = { 'chan_id': chan_id, 'intervals': intervals }

  return chan_id
endfunction



function! ExitCallback(job, status)
  call s:l('exit callback')
  let chan_id = s:channel_id(a:job)

  if empty(chan_id)
    return s:error("failed getting channel of job")
  endif

  let job = remove(s:jobs, chan_id)
  " let timer_id = remove(s:timers, job.timer_id)
  " call timer_stop(timer_id)

  let was_in_qf = &buftype ==# 'quickfix'
  exec "cg " . job.output_file
  let is_in_qf = &buftype ==# 'quickfix'
  if was_in_qf != is_in_qf
    wincmd p
  endif
  :call setqflist([], 'r', {'title': job.cmd})
endfun

fun! CheckStatus(timer_id) abort
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
    call s:l('2')
    return
  endif

  if empty(timer.intervals)
    call s:l('no more intervals')
    return
  endif

  " start a new timer
  let new_timer_id = timer_start(remove(timer.intervals, 0), 'CheckStatus')
  call s:l('new timer started' . new_timer_id)
  let s:timers[new_timer_id] = timer
endfun

function! CloseCallback(channel)
  " trigger vim calling s:ExitHandler()
  echo "CloseCallback"
  " call job_status(ch_getjob(a:channel))
endfun

function! s:channel_id(job)
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







