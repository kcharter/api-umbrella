local Admin = require "api-umbrella.web-app.models.admin"
local build_url = require "api-umbrella.utils.build_url"
local flash = require "api-umbrella.web-app.utils.flash"
local is_empty = require("pl.types").is_empty
local oauth2 = require "api-umbrella.web-app.utils.oauth2"
local t = require("api-umbrella.web-app.utils.gettext").gettext
local username_label = require "api-umbrella.web-app.utils.username_label"

local _M = {}

local function email_unverified_error(self)
  flash.session(self, "danger", string.format(t([[The email address '%s' is not verified. Please <a href="%s">contact us</a> for further assistance.]]), self.username, config["contact_url"]))
  return { redirect_to = build_url("/admin/login") }
end

local function login(self)
  local admin
  if not is_empty(self.username) then
    admin = Admin:find({ username = self.username })
  end

  if admin then
    self:init_session()
    self.resty_session:start()
    self.resty_session.data["admin_id"] = admin.id
    self.resty_session:save()

    return { redirect_to = build_url("/admin/") }
  else
    flash.session(self, "danger", string.format(t([[The account for '%s' is not authorized to access the admin. Please <a href="%s">contact us</a> for further assistance.]]), self.username, config["contact_url"]))
    return { redirect_to = build_url("/admin/login") }
  end
end

function _M.cas_login(self)
  return { redirect_to = "/" }
end

function _M.cas_callback(self)
  return { redirect_to = "/" }
end

function _M.developer_login(self)
  if config["app_env"] ~= "development" then
    return self.app.handle_404(self)
  end

  self.admin_params = {}
  self.username_label = username_label()
  return { render = "admin.auth_external.developer_login" }
end

function _M.developer_callback(self)
  if config["app_env"] ~= "development" then
    return self.app.handle_404(self)
  end

  local admin_params = _M.admin_params(self)
  if admin_params then
    local username = admin_params["username"]
    if not is_empty(username) then
      local admin = Admin:find({ username = username })
      if admin and not admin:is_access_locked() then
        self.username = username
      else
        self.current_admin = {
          id = "00000000-0000-0000-0000-000000000000",
          username = "admin",
          superuser = true,
        }
        ngx.ctx.current_admin = self.current_admin

        admin_params["superuser"] = true
        assert(Admin:create(admin_params))
        self.username = username
      end
    end
  end

  if self.username then
    return login(self)
  else
    self.admin_params = admin_params
    self.username_label = username_label()
    return { render = "admin.auth_external.developer_login" }
  end
end

function _M.facebook_login(self)
  return oauth2.authorize(self, "facebook", "https://www.facebook.com/v2.11/dialog/oauth", {
    scope = "email",
  })
end

function _M.facebook_callback(self)
  local userinfo = oauth2.userinfo(self, "facebook", {
    token_endpoint = "https://graph.facebook.com/v2.11/oauth/access_token",
    userinfo_endpoint = "https://graph.facebook.com/v2.11/me",
    userinfo_query_params = {
      fields = "email,verified",
    },
  })

  self.username = userinfo["email"]
  if not userinfo["verified"] then
    return email_unverified_error(self)
  end

  return login(self)
end

function _M.github_login(self)
  return oauth2.authorize(self, "github", "https://github.com/login/oauth/authorize", {
    scope = "user:email",
  })
end

function _M.github_callback(self)
  local userinfo = oauth2.userinfo(self, "github", {
    token_endpoint = "https://github.com/login/oauth/access_token",
    userinfo_endpoint = "https://api.github.com/user/emails",
  })

  for _, email in ipairs(userinfo) do
    if email["primary"] then
      self.username = email["email"]

      if not email["verified"] then
        return email_unverified_error(self)
      end

      break
    end
  end

  return login(self)
end

function _M.gitlab_login(self)
  return oauth2.authorize(self, "gitlab", "https://gitlab.com/oauth/authorize", {
    scope = "read_user",
  })
end

function _M.gitlab_callback(self)
  local userinfo = oauth2.userinfo(self, "gitlab", {
    token_endpoint = "https://gitlab.com/oauth/token",
    userinfo_endpoint = "https://gitlab.com/api/v4/user",
  })

  -- GitLab only appears to return verified email addresses (so there's not an
  -- explicit email verification attribute or check needed).
  self.username = userinfo["email"]
  return login(self)
end

function _M.google_login(self)
  return oauth2.authorize(self, "google", "https://accounts.google.com/o/oauth2/v2/auth", {
    scope = "openid email",
    prompt = "select_account",
  })
end

function _M.google_callback(self)
  local userinfo = oauth2.userinfo(self, "google", {
    token_endpoint = "https://www.googleapis.com/oauth2/v4/token",
    userinfo_endpoint = "https://www.googleapis.com/oauth2/v3/userinfo",
  })

  self.username = userinfo["email"]
  if not userinfo["email_verified"] then
    return email_unverified_error(self)
  end

  return login(self)
end

function _M.ldap_login(self)
  self.admin_params = {}
  self.username_label = username_label()
  return { render = "admin.auth_external.ldap_login" }
end

function _M.ldap_callback(self)
  return { redirect_to = "/" }
end

function _M.admin_params(self)
  local params = {}
  if self.params and self.params["admin"] then
    local input = self.params["admin"]
    params = {
      username = input["username"],
      password = input["password"],
    }
  end

  return params
end

return function(app)
  app:get("/admins/auth/cas(.:format)", _M.cas_login)
  app:get("/admins/auth/cas/callback(.:format)", _M.cas_callback)
  app:get("/admins/auth/developer(.:format)", _M.developer_login)
  app:post("/admins/auth/developer/callback(.:format)", _M.developer_callback)
  app:get("/admins/auth/facebook(.:format)", _M.facebook_login)
  app:get("/admins/auth/facebook/callback(.:format)", _M.facebook_callback)
  app:get("/admins/auth/github(.:format)", _M.github_login)
  app:get("/admins/auth/github/callback(.:format)", _M.github_callback)
  app:get("/admins/auth/gitlab(.:format)", _M.gitlab_login)
  app:get("/admins/auth/gitlab/callback(.:format)", _M.gitlab_callback)
  app:get("/admins/auth/google_oauth2(.:format)", _M.google_login)
  app:get("/admins/auth/google_oauth2/callback(.:format)", _M.google_callback)
  app:get("/admins/auth/ldap(.:format)", _M.ldap_login)
  app:post("/admins/auth/ldap/callback(.:format)", _M.ldap_callback)
end
