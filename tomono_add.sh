#!/bin/bash

${DEBUGSH:+set -x}
if [[ "$BASH_SOURCE" == "$0" ]]; then
	is_script=true
	set -eu -o pipefail
else
	is_script=false
fi

# Default name of the mono repository (override with envvar)
: "${MONOREPO_NAME=core}"

# Monorepo directory
monorepo_dir="$PWD/$MONOREPO_NAME"



##### FUNCTIONS

# Silent pushd/popd
pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

function read_repositories {
	sed -e 's/#.*//' | grep .
}

# Simply list all files, recursively. No directories.
function ls-files-recursive {
	find . -type f | sed -e 's!..!!'
}

# List all branches for a given remote
function remote-branches {
	# With GNU find, this could have been:
	#
	#   find "$dir/.git/yada/yada" -type f -printf '%P\n'
	#
	# but it's not a real shell script if it's not compatible with a 14th
	# century OS from planet zorploid borploid.

	# Get into that git plumbing.  Cleanest way to list all branches without
	# text editing rigmarole (hard to find a safe escape character, as we've
	# noticed. People will put anything in branch names).
	pushd "$monorepo_dir/.git/refs/remotes/$1/"
	ls-files-recursive
	popd
}

# Create a monorepository in a directory "core". Read repositories from STDIN:
# one line per repository, with two space separated values:
#
# 1. The (git cloneable) location of the repository
# 2. The name of the target directory in the core repository
function add-repos {
        if [[ ! -d "$MONOREPO_NAME" ]]; then
                echo "Nothing to add" >&2
                exit 1
        fi
        pushd "$MONOREPO_NAME"

	# This directory will contain all final tag refs (namespaced)
	mkdir -p .git/refs/namespaced-tags

        # Always move existing tags to other directory
        mv .git/refs/tags .git/refs/existing-tags

	read_repositories | while read repo name folder; do

		if [[ -z "$name" ]]; then
			echo "pass REPOSITORY NAME pairs on stdin" >&2
			return 1
		elif [[ "$name" = */* ]]; then
			echo "Forward slash '/' not supported in repo names: $name" >&2
			return 1
		fi

                if [[ -z "$folder" ]]; then
			folder="$name"
                fi

                git_remote_array=$(git remote)
                if echo "${git_remote_array[@]}" | grep -wq "$name" &>/dev/null; then
                        # If remote exists, everything all right.
                        echo "$name remote existed. Jump to next."
                        continue
                fi

		echo "Merging in $repo.." >&2
		git remote add "$name" "$repo"
		echo "Fetching $name.." >&2
		git fetch -q "$name"

                if [[ -d "$folder" ]]; then
                        # If repo folder is existed, git merge process has been done by others. Rebuild remotes only.
                        echo "$name folder existed. Jump to next."
                        continue
                fi

		# Now we've got all tags in .git/refs/tags: put them away for a sec
		if [[ -n "$(ls .git/refs/tags)" ]]; then
			mv .git/refs/tags ".git/refs/namespaced-tags/$name"
		fi

		# Merge every branch from the sub repo into the mono repo, into a
		# branch of the same name (create one if it doesn't exist).
		remote-branches "$name" | while read branch; do
			if git rev-parse -q --verify "origin/$branch"; then
			        # Branch already exists, just check it out (and clean up the working dir)
                                if git rev-parse -q --verify "$branch"; then
                                        git checkout -q "$branch"
                                else
                                        git checkout -q --track -b "$branch" "origin/$branch"
                                fi
				git checkout -q -- .
				git clean -f -d
			else
				# Create a fresh branch with an empty root commit"
				git checkout -q --orphan "$branch"
				# The ignore unmatch is necessary when this was a fresh repo
				git rm -rfq --ignore-unmatch .
				git commit -q --allow-empty -m "Root commit for $branch branch"
			fi
			git merge -q --no-commit -s ours "$name/$branch" --allow-unrelated-histories
			git read-tree --prefix="$folder/" "$name/$branch"
			git commit -q --no-verify --allow-empty -m "Merging $name to $branch"
		done
	done

        # remove tags directory first
	rm -rf .git/refs/tags

        # Restore existing tags
        mv .git/refs/existing-tags .git/refs/tags

	# Restore all namespaced tags
	mv .git/refs/namespaced-tags/* .git/refs/tags 2>/dev/null
        rm -rf .git/refs/namespaced-tags

	git checkout -q master
	git checkout -q .
        git clean -f -d
}

if [[ "$is_script" == "true" ]]; then
	add-repos "${1:-}"
fi
