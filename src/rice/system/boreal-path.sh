case ":$PATH:" in
    *:/usr/sbin:*) ;;
    *) PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin" ;;
esac
export PATH
