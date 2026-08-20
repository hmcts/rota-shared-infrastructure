# Preview Database

1. Connect to the F5 VPN
2. Run the relevant `paas_preview_password` script for your OS (Mac or Windows) to display the preview database password
3. Connect to the `rota-preview.postgres.database.azure.com` using `hmcts` as the user with the password from step 2
4. Password can be cached locally until you are told it has been changed, when you will need to retrieve the updated password

# Other Non-Production Databases

1. Connect to the F5 VPN
2. Request access to the non-production bastion server via [HMCTS Access Packages](https://myaccess.microsoft.com/@HMCTS.NET#/access-packages/4894e58f-920e-404d-9db4-dc2ab8513794)
3. Run the relevant `hmcts_platform_keys` script for your OS (Mac or Windows) to generate SSH keys that are required to connect to the bastion server
4. Run the relevant `paas_access_token` script for your OS (Mac or Windows) to generate an access token for any of the databases
5. Open a tunnel to the relevant database by SSHing to the non-production bastion server with port forwarding to the relevant database
6. Connect to the relevant database using the `DTS CFT DB Access Reader` or `DTS CFT DB Access Writer` as the user with the access token from step 4
7. Access tokens expire within hours and so should not be cached locally, because you will have to request a new one the next time you connect
