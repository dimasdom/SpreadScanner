<#--
  Overrides keycloak.v2's login-reset-password.ftl: the old pre-Keycloak app
  UI has a single "Send code" button (no separate "Back to Login" button)
  plus a "Sign in" / "Register" link row at the bottom, instead of stock's
  Submit + secondary Back-to-Login button pair and a plain instructional
  paragraph. displayInfo is turned off since that paragraph has no place in
  the old layout.
-->
<#import "template.ftl" as layout>
<#import "field.ftl" as field>
<#import "buttons.ftl" as buttons>
<@layout.registrationLayout displayInfo=false displayMessage=!messagesPerField.existsError('username'); section>
<!-- template: login-reset-password.ftl (arbiscanner theme) -->
    <#if section = "header">
        ${msg("arbResetTitle")}
    <#elseif section = "form">
        <form id="kc-reset-password-form" class="${properties.kcFormClass!}" action="${url.loginAction}" method="post">
            <#assign label>
                <#if !realm.loginWithEmailAllowed>${msg("username")}<#elseif !realm.registrationEmailAsUsername>${msg("usernameOrEmail")}<#else>${msg("email")}</#if>
            </#assign>
            <@field.input name="username" label=label value=auth.attemptedUsername!'' autofocus=true />

            <@buttons.actionGroup>
              <@buttons.button id="kc-form-buttons" label="arbSendCode" class=["kcButtonPrimaryClass", "kcButtonBlockClass"]/>
            </@buttons.actionGroup>

            <div class="arb-auth-links">
                <a href="${url.loginUrl}">${msg("arbSignIn")}</a>
                <#if realm.registrationAllowed && !registrationDisabled??>
                    <a href="${url.registrationUrl}">${msg("doRegister")}</a>
                <#else>
                    <span></span>
                </#if>
            </div>

        </form>
    </#if>
</@layout.registrationLayout>
