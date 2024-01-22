# Extends Genesis::Env::Secrets::Parser::FromManifest to support legacy CF kits
use Genesis::Secret::UserProvided;

sub process_legacy_cf_secrets {
	my ($secrets, $features) = @_;

	# Make cc_db_encryption_key fixed
	my ($cc_db_encryption_key_secret) = grep {$_->path eq 'cc_db_encryption_key'} @$secrets;
	$cc_db_encryption_key_secret->set(fixed => 1) if $cc_db_encryption_key_secret;

	# External Database
	if (in_array('mysql-db', @$features) || in_array('postgres-db', @$features)) {
		my $inst = in_array('mysql-db', @$features) ? 'MySQL' : 'PostgreSQL';
		push @$secrets, Genesis::Secret::UserProvided->new('external_db:username',
			prompt    => "What is your external $inst database username?",
			sensitive => 1,
			fixed     => 1,
			_ch_name  => "external_db_user"
		);
		push @$secrets, Genesis::Secret::UserProvided->new('external_db:password',
			prompt    => "What is the password for the external $inst database user",
			sensitive => 1,
			fixed     => 1,
			_ch_name  => "external_db_password"
		);
	}

	# Fix user-provided haproxy
	if (in_array('haproxy', @$features) && in_array('tls', @$features) && ! in_array('self-signed', @$features)) {
		push @$secrets, Genesis::Secret::UserProvided->new("haproxy_ssl:certificate",
			prompt    => "HA Proxy SSL certificate",
			sensitive => 1,
			multiline => 1,
			fixed     => 1,
			_ch_name  => "haproxy_ssl.certificate"
		);
		push @$secrets, Genesis::Secret::UserProvided->new("haproxy_ssl:key",
			prompt    => "HA Proxy SSL key",
			sensitive => 1,
			multiline => 1,
			fixed     => 1,
			_ch_name  => "haproxy_ssl.private_key"
		);
		push @$secrets, Genesis::Secret::UserProvided->new("haproxy_ca:certificate",
			prompt    => "HA Proxy CA certificate",
			sensitive => 1,
			multiline => 1,
			fixed     => 1,
			_ch_name  => "haproxy_ca.certificate"
		);
		push @$secrets, Genesis::Secret::UserProvided->new("haproxy_ca:key",
			prompt    => "HA Proxy CA key",
			sensitive => 1,
			multiline => 1,
			fixed     => 1,
			_ch_name  => "haproxy_ca.private_key"
		);
	}

	# AWS blobstore
	if (in_array('aws-blobstore', @$features)) {
		push @$secrets, Genesis::Secret::UserProvided->new('blobstore:aws_access_key',
			prompt    => "What is your Amazon S3 Access Key ID",
			sensitive => 1,
			fixed     => 1,
			_ch_name  => "blobstore_access_key_id"
		);
		push @$secrets, Genesis::Secret::UserProvided->new('blobstore:aws_access_secret',
			prompt    => "What is your Amazon S3 Secret Access Key",
			sensitive => 1,
			fixed     => 1,
			_ch_name  => "blobstore_secret_access_key"
		);
	}

	# Azure blobstore
	if (in_array('azure-blobstore', @$features)) {
		push @$secrets, Genesis::Secret::UserProvided->new('blobstore:storage_account_name',
			prompt    => "What is your Azure Storage Account Name",
			sensitive => 1,
			fixed     => 1,
			_ch_name  => "blobstore_storage_account_name"
		);
		push @$secrets, Genesis::Secret::UserProvided->new('blobstore:storage_access_key',
			prompt    => "What is your Azure Storage Account Key",
			sensitive => 1,
			fixed     => 1,
			_ch_name  => "blobstore_storage_access_key"
		);
	}

	# Google blobstore
	if (in_array('gcp-blobstore', @$features)) {
		if (in_array('gcp-use-access-key', @$features)) {
			push @$secrets, Genesis::Secret::UserProvided->new('blobstore:gcp_access_key',
				prompt    => "What is your Google Cloud Storage access key",
				sensitive => 1,
				fixed     => 1,
				_ch_name  => "blobstore_access_key_id"
			);
			push @$secrets, Genesis::Secret::UserProvided->new('blobstore:gcp_secret_key',
				prompt    => "What is your Google Cloud Storage secret access key",
				sensitive => 1,
				fixed     => 1,
				_ch_name  => "blobstore_secret_access_key"
			);
		} else {
			push @$secrets, Genesis::Secret::UserProvided->new('blobstore:gcp_project_name',
				prompt    => "What is your Google Cloud Project Name",
				sensitive => 1,
				fixed     => 1,
				_ch_name  => "gcs_project"
			);
			push @$secrets, Genesis::Secret::UserProvided->new('blobstore:gcp_client_email',
				prompt    => "What is the Cloud Storage Service Account ID (@<project>.iam.gserviceaccount.com)",
				sensitive => 1,
				fixed     => 1,
				_ch_name  => "gcs_service_account_email"
			);
			push @$secrets, Genesis::Secret::UserProvided->new('blobstore:gcp_json_key',
				prompt    => "What is the Cloud Storage Service Account (JSON) Key",
				sensitive => 1,
				fixed     => 1,
				multiline => 1,
				_ch_name  => "gcs_service_account_json_key"
			);
		}
	}
}

1;
