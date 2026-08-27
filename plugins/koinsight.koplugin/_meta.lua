local _ = require("gettext")
return {
  name = "koinsight",
  fullname = _("KoInsight"),
  description = _([[KoInsight sync plugin.]]),
  -- `version` and `repository` are stamped by ./stamp-plugin-meta.sh when a
  -- release is built. They are only used by the self-updater; the sync protocol
  -- version the server validates lives in const.lua.
  version = "0.0.0-snapshot",
  repository = "guerrerotook/KoInsight",
}
