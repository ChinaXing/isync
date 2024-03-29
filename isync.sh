#!/bin/bash

LOG_FILE="isync.log"

QUEUE_FILE="/tmp/isync.queue"

DAEMONIZE=FALSE

DEBUG=FALSE

NOTIFY_BIN=/usr/local/bin/inotifywait
NOTIFY_PATH=/home/admin/resource/
NOTIFY_EVENTS="attrib,close_write,moved_to,moved_from,delete"
NOTIFY_EXCLUDE="^.*~\$"
NOTIFY_FORMAT="%:e %w%f"

RSYNC_BIN=/usr/bin/rsync
RSYNC_TMPDIR=".irsync_rsync_tmpdir"
RSYNC_PARAM="-aR -u"
RSYNC_PARAM_DELETE=" -r --exclude='/*/*/*' -R --delete --delete-excluded "
RSYNC_USER="isyncer"
RSYNC_MODULE="resource"

# ------- build the default variable ------- #
VARS=( NOTIFY_BIN NOTIFY_PATH NOTIFY_EVENTS NOTIFY_EXCLUDE NOTIFY_FORMAT RSYNC_BIN
RSYNC_TMPDIR RSYNC_PARAM LOG_FILE QUEUE_FILE
)

for v in ${VARS[@]}
do
    eval DEFAULT_$v=\$$v
done

# -- no longer use -- #
# ------- util fuctions ------------------ #
#function get_prefix
#{
#    local nln=""
#    for e in "${@}"
#    do
#        echo "$e"
#    done | sort -u | \
#        while read ln
#        do
#            if [ -z $nln ]
#            then
#                nln=$ln
#                echo $ln
#                continue
#            fi
#            if [ "${ln##$nln}" = "$ln" ]
#            then
#                echo $ln
#                nln=$ln
#            fi
#        done
#}

function backup_fd
{
    # -- backup standard input/output/err
    if [[ "${BASH_VERSINFO[@]:0:2}" > "4 1" ]]
    then
        exec {input}<&0 {output}>&1 {errput}>&2
    else
        exec 7<&0 8>&1 9>&2
        input=7 output=8 errput=9
    fi
}

function recover_fd
{
    # -- recover standart input/output/err
    exec 0<&${input}- 1>&${output}- 2>&${errput}-
}

function debug
{
    if [ $DEBUG = TRUE ]
    then
        :
    else
        exec 1>/dev/null 2>/dev/null 0</dev/null
    fi
}

function logger
{
    local level="$1" subject="$2" message="$3"
    printf "[%-8s] <%-12s> %s\n" $level "$subject" "$message"
}


function do_rsync
{
    logger "INFO" "sync file" "$*"
    backup_fd
    debug
    if [ $DEBUG = TRUE ]
    then
        logger "DEBUG" "RSYNC_CMD" """
    cd $NOTIFY_PATH && \
        $RSYNC_BIN $RSYNC_PARAM -T ${RSYNC_TMPDIR} "$@" \
        $RSYNC_USER@$TARGET_SERVER::$RSYNC_MODULE
        """
    fi
    cd $NOTIFY_PATH && \
        $RSYNC_BIN $RSYNC_PARAM -T ${RSYNC_TMPDIR} "$@" \
        $RSYNC_USER@$TARGET_SERVER::$RSYNC_MODULE
    local Rcode=$?
    recover_fd

    if [ $Rcode -ne 0 ]
    then
        logger "ERROR" "rsync return $Rcode" "FILES:$@"
    fi
}

function do_delete
{
    cd $NOTIFY_PATH
    local file=() i=0
    for f in "$@"
    do
        # -- exclude unexist file (which means its parent has been deleted)-- #
        if test -e $NOTIFY_PATH$f
        then
            file[$i]="$f"
            ((i++))
        fi
    done
    [ $i -eq 0 ] && return

    logger "INFO" "delete file" "${file[@]}"
    backup_fd
    debug
    if [ $DEBUG = TRUE ]
    then
        logger "DEBUG" "RSYNC_CMD" """
    cd $NOTIFY_PATH && \
        $RSYNC_BIN $RSYNC_PARAM_DELETE -T ${RSYNC_TMPDIR} "${file[@]}" \
        $RSYNC_USER@$TARGET_SERVER::$RSYNC_MODULE
        """
    fi
    cd $NOTIFY_PATH && \
        $RSYNC_BIN $RSYNC_PARAM_DELETE -T ${RSYNC_TMPDIR} "${file[@]}" \
        $RSYNC_USER@$TARGET_SERVER::$RSYNC_MODULE
    local Rcode=$?
    recover_fd
    if [ $Rcode -ne 0 ]
    then
        logger "ERROR" "rsync return $Rcode" "FILES:${file[@]}"
    fi

}

function run_event_proc
{

    local event file
    if [[ "${BASH_VERSINFO[@]:0:2}" > "4 1" ]]
    then
        exec {q_input}<$QUEUE_FILE
    else
        exec 6<$QUEUE_FILE
        q_input=6
    fi

    # wait inotifywait write event to QUEUE_FILE
    while $NOTIFY_BIN -e modify $QUEUE_FILE -q >/dev/null 2>/dev/null
    do
        while read -u ${q_input} -a ln
        do
            event=${ln[0]} file=${ln[1]}
            if [ -z "$file" ] || [ -z "$event" ]
            then
                logger "ERROR" "bad event found" "$event"
                continue
            fi

            if [ "$file" = "./${RSYNC_TMPDIR}" ]
            then
                continue
            fi
            if [ $DEBUG = TRUE ]
            then
                logger "DEBUG" "Event" "$event:$file"
            fi
            # // process event
            case "$event" in
                ATTRIB|ATTRIB:ISDIR) do_rsync "$file"
                    ;;
                CLOSE_WRITE:CLOSE) do_rsync "$file"
                    ;;
                DELETE|DELETE:ISDIR) do_delete "${file%/*}"
                    ;;
                MOVED_TO) do_rsync "$file"
                    ;;
                MOVED_FROM) do_delete "${file%/*}"
                    ;;
                *) logger "ERROR" "uncapture event found, ignore" "$event"
                    ;;
            esac
        done
    done
    exit 0
}

function run_inotify
{
    cd $NOTIFY_PATH
    $NOTIFY_BIN \
        -r \
        -m \
        -q \
        @./${RSYNC_TMPDIR} \
        -e $NOTIFY_EVENTS \
        --format "$NOTIFY_FORMAT" \
        --excludei "$NOTIFY_EXCLUDE" \
        ./ \
        > $QUEUE_FILE 2>/dev/null
    logger "INFO" "inotifywait exist" "PID:$$"
    exit 0
}


function monitor
{
    if ! [ -e /proc/$INOTIFY_PID/ ]
    then
        wait $INOTIFY_PID
        logger "INFO" "MONITOR:" "notifywait($NOTIFY_PID) exit, respwan it ..."
        run_inotify &>/dev/null &
        # INOTIFY_PID
        INOTIFY_PID=$!
        logger "INFO" "MONITOR:" "respwan inotifywait done, pid=$INOTIFY_PID"
    fi
    if ! [ -e /proc/$EVENT_PROC_PID/ ]
    then
        wait $EVENT_PROC_PID
        logger "INFO" "MONITOR:" "event_proc($EVENT_PROC_PID) exit, respwan it ..."
        run_event_proc &>/dev/null &
        # EVENT_PROC_PID
        EVENT_PROC_PID=$!
        logger "INFO" "MONITOR:" "respwan event_proc done, pid=$EVENT_PROC_PID"
    fi
}

function reap_child
{
    logger "INFO" "KILL CHILD:" "$INOTIFY_PID $EVENT_PROC_PID"
    kill -9 0
    exit 0
}

function run
{
    # inotifywait run in background as a daemon
    run_inotify &
    # INOTIFY_PID
    INOTIFY_PID=$!

    # process event
    run_event_proc &
    # EVENT_PROC_PID
    EVENT_PROC_PID=$!

    # monitor inotify and process_event
    trap monitor SIGCHLD

    # if exit reap children
    trap reap_child  EXIT

    # sleep
    while :
    do
        sleep 1000
    done
}

function main
{
    if [ $DAEMONIZE = TRUE ]
    then
        run &>$LOG_FILE </dev/null &
        local pid=$!
        disown $pid  # prevent SIGHUP from session leader
    else
        run
    fi
}

function usage
{
    cat <<EOF
$0 -- Use inotifywait and rsync tool to sync change between two Server

OPTIONS:
   -c    configure file to source
   -t    target server to sync to
   -d    daemonize , by default isync will run in foreground
   -D    debug mode, output some detail info
   -l    Logfile path, default : $DEFAULT_LOG_FILE
   -q    queue file, use to exchange task between intofiy and rsync, default $DEFAULT_QUEUE_FILE
   -p    monite path, default : $DEFUALT_NOTIFY_BIN
   -i    inotifywait path, default : $DEFUALT_NOTIFY_BIN
   -r    rsync path, default : $DEFAULT_RSYNC_BIN
   -x    param of inotifywait\'s --excludei, default : $DEFAULT_NOTIFY_EXCLUDE
   -T    rsync temporary dir in remote, default : ${DEFAULT_RSYNC_TMPDIR}
   -h    this message

*NOTICE: Need bash version >=3.2

EOF
   exit 0
}

function init
{
    local Params=()
    while getopts "c:t:dDl:q:p:i:r:x:T:h" OPTION
    do
        case $OPTION in
            c) echo "use Configure file:" $OPTARG
                CONFIG_FILE=$OPTARG
                ;;
            t) echo "use TARGET_SERVER:" $OPTARG
                P_TARGET_SERVER=$OPTARG
                Params="$Params TARGET_SERVER"
                ;;
            d) echo "use DAEMONIZE:"
                P_DAEMONIZE=TRUE
                Params="$Params DAEMONIZE"
                ;;
            D) echo "use DEBUG"
                P_DEBUG=TRUE
                Params="$Params DEBUG"
                ;;
            l) echo "use LOG_FILE:" $OPTARG
                P_LOG_FILE=$OPTARG
                Params="$Params LOG_FILE"
                ;;
            q) echo "use QUEUE_FILE:" $OPTARG
                P_QUEUE_FILE=$OPTARG
                Params="$Params QUEUE_FILE"
                ;;
            p) echo "use NOTIFY_PATH:" $OPTARG
                P_NOTIFY_PATH=$OPTARG
                Params="$Params NOTIFY_PATH"
                ;;
            i) echo "use NOTIFY_BIN:" $OPTARG
                P_NOTIFY_BIN=$OPTARG
                Params="$Params NOTIFY_BIN"
                ;;
            r) echo "use RSYNC_BIN:" $OPTARG
                P_RSYNC_BIN=$OPTARG
                Params="$Params RSYNC_BIN"
                ;;
            x) echo "use EXECLUDE_REGEXP:" $OPTARG
                P_NOTIFY_EXCLUDE=$OPTARG
                Params="$Params NOTIFY_EXCLUDE"
                ;;
            T) echo "use RSYNC_TMPDIR:" $OPTARG
                P_RSYNC_TMPDIR=$OPTARG
                Params="$Params RSYNC_TMPDIR"
                ;;
            h) usage
                ;;
            \?) break
                ;;
        esac
    done

    # merge conf
    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]
    then
        source $CONFIG_FILE
    fi

    for p in $Params
    do
        eval $p=\"\${P_$p}\"
    done

    # // validation

    # -- TARGET_SERVER
    if test -z $TARGET_SERVER
    then
        echo "ERROR: You must specify a remote server, abort "
        exit 1
    fi

    # -- DAEMONIZE
    if test $DAEMONIZE = TRUE
    then
        # -- LOG_FILE
        if ! test -f $LOG_FILE && ! touch $LOG_FILE
        then
            echo "ERROR: LOG_FILE cannot create, abort : " $LOG_FILE
            exit 2
        fi
    fi

    # -- DEBUG
    if test $DEBUG = TRUE
    then
        RSYNC_PARAM="$RSYNC_PARAM -v"
        RSYNC_PARAM_DELETE="$RSYNC_PARAM_DELETE -v"
    fi

    # -- NOTIFY_PATH
    if ! test -d $NOTIFY_PATH
    then
        echo "ERROR: NOTIFY_PATH unexist, abort : " $NOTIFY_PATH
        exit 3
    fi

    # -- NOTIFY_BIN
    if ! test -f $NOTIFY_BIN
    then
        echo "ERROR: NOTIFY_BIN unexist, abort : " $NOTIFY_BIN
        exit 4
    fi

    # -- RSYNC_BIN
    if ! test -f $RSYNC_BIN
    then
        echo "ERROR: RSYNC_BIN unexist, abort : " $RSYNC_BIN
        exit 5
    fi
    # -- RSYNC_TMPDIR
    if ! test -d ${NOTIFY_PATH}$RSYNC_TMPDIR && ! mkdir -p ${NOTIFY_PATH}$RSYNC_TMPDIR
    then
        echo "ERROR: Make rsync temporary dir failed, abort : " ${NOTIFY_PATH}$RSYNC_TMPDIR
        exit 6
    fi

}

###################################################
if [[ "${BASH_VERSINFO[@]:0:2}" < "3 2" ]]
then
    echo "You need a new version of Bash >=3.2 ."
    exit -1
fi

init $@
main
###################################################
