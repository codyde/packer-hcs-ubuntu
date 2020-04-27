# Terraform Example - Post Packer Build

After building my image with Packer, I'll typically load up a Terraform Cloud workspace for deploying my machines into HCS.
The manifest in this directory is a sample of what I use to do that deployment. 


This manifest could easily be updated to include creating files on the local machine for service registration in Consul - thus
completing the application configuration.