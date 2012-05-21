#!/bin/bash

# set -x

DEBUG=0
DRY_RUN=0

if [ -z "$DRY_RUN" ] ; then
    DRY_RUN=0
fi

warning()
{
    echo "WARNING: $@" 1>&2
}

debug()
{
    if [ "$DEBUG" = "1" ] ; then
        echo "DEBUG: $@"
    fi
}

do_cvs()
{
    if [ $DRY_RUN -ne 0 ] ; then
        cvs -d "$CVS_ROOT" -n "$@"
    else
        cvs -d "$CVS_ROOT" "$@"
    fi
}

add_cvsfolder()
{
    a="$1"
    p=
    first="/*"
    second="*/"

    if [ "$a" != "." ]
    then
        while [ "$a" != "$p" ]
        do
            p="$a"
            f="${a/$first}"
            a="${a#$second}"
            if [ ! -d "$f/CVS" ] ; then
                do_cvs -Q add "$f"
            fi
            cd "$f"
        done
    fi
}

cvs_lock_files()
{
    if [ "x$@" != "x" ] ; then
        do_cvs -Q admin -l "$@"
    fi
}

cvs_unlock_files()
{
    if [ "x$@" != "x" ] ; then
        do_cvs -Q admin -u "$@"
    fi
}

do_cvsimport()
{
    local hg_rev="$1"
    local is_merge="$2"

    hg up -C $hg_rev
    if [ $? -ne 0 ] ; then
        warning "Unable to update working copy to $rev"
        return 1
    fi

    local file_list=/tmp/hg2cvs.${hg_rev}.changes
    hg log --style "$HG_FILES_STYLE" -r "$hg_rev" > $file_list
    if [ $? -ne 0 ] ; then
        warning "Unable to identify affected files"
        rm -f $file_list
        return 1
    fi

    local added_files=()
    local changed_files=()
    local removed_files=()

    while read line
    do
        local mod_type=${line:0:1}
        local mod_file="${line:2}"

        # skip .hg* files
        if [ "${mod_file:0:3}" = ".hg" ] ; then
            continue;
        fi

        case $mod_type in
            A) added_files[${#added_files[@]}]="$mod_file"     ;;
            M) changed_files[${#changed_files[@]}]="$mod_file" ;;
            R) deleted_files[${#deleted_files[@]}]="$mod_file" ;;
            *) warning "Bad modification type $mod_type" ; return 1 ;;
        esac

    done < $file_list
    rm $file_list

    debug added: "${added_files[@]}"
    debug changed: "${changed_files[@]}"
    debug deleted: "${deleted_files[@]}"

    local n_files=$((${#deleted_files[@]} + ${#added_files[@]} + ${#changed_files[@]}))
    if [ "$n_files" -eq 0 ] ; then
        debug "Nothing to commit to CVS"
        return 0;
    fi

    if [ ${#deleted_files[@]} -gt 0 ] ; then
        do_cvs remove -f "${deleted_files[@]}"
    fi

    for added in "${added_files[@]}"
    do
         pushd .
         local dirpath=$(dirname "$added")
         add_cvsfolder "$dirpath"
         if [ $? -ne 0 ]; then
             return 1
         fi

         local filename=$(basename "$added")
         do_cvs add "$filename"
         if [ $? -ne 0 ]; then
             return 1
         fi
         popd
    done

    local descfile=/tmp/hg2cvs.desc.$hg_rev
    local revspec=$hg_rev
    if [ -n "$is_merge" ] ; then
        revspec="ancestors($hg_rev) - ancestors(${hg_rev}^1)"
    fi

    hg log --template "{desc}\n-- {author} {date|isodatesec} commit {node|short}\n\n" -r "$revspec" > $descfile

    cvs_lock_files "${deleted_files[@]}" "${changed_files[@]}"
    if [ $? -ne 0 ] ; then
        warning Unable to CVS-lock files
        cvs_unlock_files "${deleted_files[@]}" "${changed_files[@]}"
        return 1
    fi

    # dry run to check if commit succeeds
    do_cvs -Q -n commit -F $descfile "${added_files[@]}" "${deleted_files[@]}" "${changed_files[@]}"
    if [ $? -ne 0 ] ; then
        warning CVS commit verification failed
        cvs_unlock_files "${deleted_files[@]}" "${changed_files[@]}"
        return 1
    fi

    # real commit, we don't expect it to fail
    # if succeeded, commit releases all the locks held
    do_cvs -Q commit -F $descfile "${added_files[@]}" "${deleted_files[@]}" "${changed_files[@]}"
    local ret=$?
    if [ $ret -ne 0 ] ; then
        warning CVS commit failed, revision $hg_rev might be half-commited to CVS
        cvs_unlock_files "${deleted_files[@]}" "${changed_files[@]}"
    fi

    rm $descfile
    return $ret
}

export_commits()
{
    local branch="$1"
    local history_file="$2"

    local last_imported_rev=null
    if [ -f "$history_file" ] ; then
        last_imported_rev=$(tail -n 1 "$history_file")
    fi
    debug "Last imported revision: $last_imported_rev"

    local heads=$(hg log --template '{node} ' -r "heads(branch($branch))")
    debug "Heads: $heads"

    if [ -n "$(echo $heads | grep $last_imported_rev)" ] ; then
        echo "Branch $branch is up to date"
        return 0;
    fi

    while true; do
        if [ "$last_imported_rev" = "null" ] ; then
            last_imported_rev=$(hg log --template '{node}' -r "roots(branch($branch))")
            # TODO bail out if more than one root
        else
            last_imported_rev=$(hg log --template '{node}' \
                               -r "branch($branch) and first(children(${last_imported_rev}), 1)")
        fi

        local is_merge=$(hg log --template '{node}' -r "merge() and $last_imported_rev" )
        local tags=$(hg log --template '{tags}' -r $last_imported_rev | sed 's|tip||')

        echo Importing $last_imported_rev

        if [ -n "$tags" ] ; then
            debug "$last_imported_rev TAGGED $tags"
        fi

        if [ -n "$is_merge" ] ; then
            echo "$last_imported_rev is a MERGE changeset";
        fi

        do_cvsimport "$last_imported_rev" "$is_merge"
        if [ $? -ne 0 ] ; then
            warning "CVS import of $last_imported_rev failed"
            return 1
        fi

        echo $last_imported_rev > $history_file

        for t in $tags ; do
            echo Tagging with $t
            do_cvs -Q tag -F -R $t .
            if [ $? -ne 0 ]; then
                warning CVS tag has failed: $t
            fi
        done

        if [ -n "$(echo $heads | grep $last_imported_rev)" ] ; then
            break;
        fi
    done
}

###############################################################################
# ENTRY POINT                                                                 #
###############################################################################

if [ $# -ne 2 ] ; then
    echo "Usage: hg2cvs <cvsroot> <cvs-sandbox-path>"
    exit 1
fi

CVS_ROOT="$1"
CVS_SANDBOX="$2"
HG_FILES_STYLE=$(dirname $0)/files.style

hg_branches=$(hg branches | cut -f 1 -d ' ')

echo "============== hg2cvs =============="

for branch in $hg_branches
do
    cvs_branch="${CVS_SANDBOX}/${branch}"
    if [ ! -d "$cvs_branch" ]; then
        echo "Skipping unmapped HG branch ${branch}"
        continue
    fi

    echo "Importing branch $branch"
    hg push -b $branch "$cvs_branch"
    if [ $? -ne 0 ] ; then
        warning "Push to $cvs_branch failed, skipping"
        continue
    fi

    history_file="$(pwd)/.hg/hg2cvs.${branch}.history"

    pushd "$cvs_branch" > /dev/null 2>&1
    export_commits "$branch" "$history_file"
    popd                > /dev/null 2>&1
done

echo "============== done hg2cvs =============="

