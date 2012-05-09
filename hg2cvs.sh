#!/bin/bash

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
        cvs -n "$@"
    else
        cvs "$@"
    fi
}

add_cvsfolder()
{
    cvsflag=
    if [ $DRY_RUN -eq 1 ]
    then
        cvsflag=-n
    fi
    a=$1
    p=
    first="/*"
    second="*/"

    if [ "$a" != "." ]
    then 
        while [ "$a" != "$p" ]
        do
            p=$a
            f=${a/$first}
            a=${a#$second}
            cvs $cvsflag add $f
            cd $f
        done
    fi  
}

do_cvsimport()
{
    local hg_rev="$1"
    local is_merge="$2"
    local tags="$3"

    hg up -C $hg_rev
    if [ $? -ne 0 ] ; then
        warning "Unable to update working copy to $rev"
        return 1
    fi

    added_files=$(hg log --template "{file_adds}\n" -r "$hg_rev" | perl -ne "s/ /\\ /g;print;")
    if [ $? -ne 0 ] ; then
        warning "Unable to identify added files"
        return 1
    fi

    changed_files=$(hg log --template "{file_mods}\n" -r "$hg_rev" | perl -ne "s/ /\\ /g;print;")
    if [ $? -ne 0 ] ; then
        warning "Unable to identify modified files"
        return 1
    fi

    removed_files=$(hg log --template "{file_dels}\n" -r "$hg_rev" | perl -ne "s/ /\\ /g;print;")
    if [ $? -ne 0 ] ; then
        warning "Unable to identify removed files"
        return 1
    fi

    added_files=${added_files/.hgtags/}
    changed_files=${changed_files/.hgtags/}

    debug "added: $added_files"
    debug "changed: $changed_files"
    debug "removed: $removed_files"

    if [ -n "$added_files" ] ; then
        for i in $added_files
        do
            pushd .
            add_cvsfolder $(dirname $i)
            if [ $? -ne 0 ]; then
                return 1
            fi

            do_cvs add $(basename $i)
            if [ $? -ne 0 ]; then
                return 1
            fi
            popd
        done
    fi

    if [ -n "$removed_files" ] ; then
        do_cvs remove -f $removed_files
    fi


    local descfile=/tmp/hg2cvs.desc.$hg_rev
    local revspec=$hg_rev
    if [ -n "$is_merge" ] ; then
        revspec="ancestors($hg_rev) - ancestors(${hg_rev}^1)"
    fi

    hg log --template "{desc}\n-- {author} {date|isodatesec} commit {node|short}\n\n" -r "$revspec" > $descfile
    do_cvs -Q commit -F $descfile $added_files $deleted_files $changed_files
    local ret=$?
    rm $descfile

    for t in $tags ; do
        echo Tagging with $t
        do_cvs -Q tag -F -R $t .
        if [ $? -ne 0 ]; then
            return 1
        fi
    done
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

        do_cvsimport "$last_imported_rev" "$is_merge" "$tags"
        if [ $? -ne 0 ] ; then
            warning "CVS import of $last_imported_rev failed"
            return 1
        fi

        echo $last_imported_rev > $history_file

        if [ -n "$(echo $heads | grep $last_imported_rev)" ] ; then
            break;
        fi
    done
}

###############################################################################
# ENTRY POINT                                                                 #
###############################################################################

CVS_SANDBOX="$1"

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

## hg_root=$(hg root)
## perror "Not in mercurial repo"
## cd $hg_root
## 
## CVSIMPORT_HISTORY=$hg_root/.hg/cvsimport.history
## 
## if [ $# -lt 1 ] ; then
##     echo "At least 1 hg revision to import should be specified"
##     echo "Usage: $0 [rev] ..."
##     exit 1
## fi
## 
## for rev in $@ ; do
##     hg_rev=$(hg id -i -r $rev)
##     perror "Unable to identify mercurial revision for $rev"
## 
##     echo Processing "$rev ($hg_rev)"
## 
##     hg up -C -r $hg_rev
##     perror "Unable to update to $rev ($hg_rev)"
## 
##     if [ -n "$(grep $hg_rev $CVSIMPORT_HISTORY 2>/dev/null)" ] ; then
##         echo "Skipping already CVS-imported $rev ($hg_rev)"
##         continue
##     fi
## 
##     do_cvsimport $hg_rev
## 
##     if [ $DRY_RUN -eq 0 ] ; then
##         echo $(hg log -r $hg_rev -l 1 --template "{rev}:$hg_rev") >> $CVSIMPORT_HISTORY
##     fi
## done
## 
## cd - > /dev/null

