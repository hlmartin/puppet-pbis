class pbis (
  $ad_domain,
  $bind_username,
  $bind_password,
  $ou                    = $pbis::params::ou,
  $enabled_modules       = $pbis::params::enabled_modules,
  $disabled_modules      = $pbis::params::disabled_modules,
  $package               = $pbis::params::package,
  $package_prerequired   = $pbis::params::package_prerequired,
  $package_file_suffix   = $pbis::params::package_file_suffix,
  $package_file_provider = $pbis::params::package_file_provider,
  $service_name          = $pbis::params::service_name,
  $assume_default_domain = $pbis::params::assume_default_domain,
  $create_home_dir       = $pbis::params::create_home_dir,
  $domain_separator      = $pbis::params::domain_separator,
  $space_replacement     = $pbis::params::space_replacement,
  $home_dir_prefix       = $pbis::params::home_dir_prefix,
  $home_dir_umask        = $pbis::params::home_dir_umask,
  $home_dir_template     = $pbis::params::home_dir_template,
  $login_shell_template  = $pbis::params::login_shell_template,
  $require_membership_of = $pbis::params::require_membership_of,
  $skeleton_dirs         = $pbis::params::skeleton_dirs,
  $user_domain_prefix    = $pbis::params::user_domain_prefix,
  $use_repository        = $pbis::params::use_repository,
  ) inherits pbis::params {

  if $use_repository == true {
    # If the package is on an external repo, install it normally
    # Make sure that if installing pbis enterprise where pbis open is already installed, remove open first!
    if $package == 'pbis-enterprise' {
      exec { 'leave_domain':
      path    => ['/bin', '/usr/bin', '/opt/pbis/bin'],
      command => "domainjoin-cli leave ${bind_username} '${bind_password}'",
      onlyif  => "rpm -qa | grep -c pbis-open", #"domainjoin-cli query | grep 'Distinguished Name'"
      before  => Package['pbis-open'],
      #refreshonly => true
      
      }
      
      package { 'pbis-open':
        ensure => absent,
        before => Package['pbis-enterprise'],
        #notify => Exec['leave_domain']
      }
    }
    package { $package:
      ensure  => latest,
    }
  }
  elsif $use_repository == false {
    # Otherwise, download and install the package from the puppetmaster...
    # a low-performance repo for the poor man
    
    # Compatibilitity switch for pbis <= v7.1.0
    # require also the prerequired package if it is not set to empty string
    if $package_prerequired == "" {
	  $require_for_package = File["/opt/${package}.${package_file_suffix}"]
    }
    else {
      $require_for_package = [
        File["/opt/${package}.${package_file_suffix}"],
        Package[$package_prerequired]
      ]
    }
    
    file { "/opt/${package}.${package_file_suffix}":
      ensure  => file,
      source  => "puppet:///modules/pbis/${package}.${package_file_suffix}",
    }
    package { $package:
      ensure   => latest,
      source   => "/opt/${package}.${package_file_suffix}",
      provider => $package_file_provider,
      require  => $require_for_package
    }
    # install the prerequired package if it is not set to empty string
    unless $package_prerequired == "" {
      file { "/opt/${package_prerequired}.${package_file_suffix}":
	    ensure => file,
	    source => "puppet:///modules/pbis/${package_prerequired}.${package_file_suffix}",
	  }
      package { $package_prerequired:
        ensure   => latest,
        source   => "/opt/${package_prerequired}.${package_file_suffix}",
        provider => $package_file_provider,
        require  => File["/opt/${package_prerequired}.${package_file_suffix}"],
      }
    }
  }
  else {
    fail("Invalid input for use_repository: ${use_repository}.")
  }

  service { $service_name:
    ensure     => running,
    restart    => '/opt/pbis/bin/lwsm restart lsass',
    start      => '/opt/pbis/bin/lwsm start lsass',
    stop       => '/opt/pbis/bin/lwsm stop lsass',
    status     => '/opt/pbis/bin/lwsm status lsass',
    require    => Package[$package],
  }

  # Construct the domainjoin-cli options string
  # AssumeDefaultDomain and UserDomainPrefix are configured after joining
  if $ou {
    $ou_path = transform_ou($ou)
    $opt_ou = "--ou ${ou_path}"
  }
  else {
    $opt_ou = ''
  }
  if $enabled_modules {
    $opt_enabled_modules = "--enable ${enabled_modules}"
  }
  else {
    $opt_enabled_modules = ''
  }
  if $disabled_modules {
    $opt_disabled_modules = "--disable ${disabled_modules}"
  }
  else {
    $opt_disabled_modules = ''
  }

  $options = "${opt_ou} ${opt_enabled_modules} ${opt_disabled_modules}"

  # Join the machine if it is not already on the domain.
  exec { 'join_domain':
    path    => ['/bin', '/usr/bin', '/opt/pbis/bin'],
    command => "domainjoin-cli join ${options} ${ad_domain} ${bind_username} '${bind_password}'",
    require => Service[$service_name],
    unless  => 'lsa ad-get-machine account 2> /dev/null | grep "NetBIOS Domain Name"',
  }

  # Update DNS
  exec { 'update_DNS':
    path    => ['/opt/pbis/bin'],
    command => 'update-dns',
    require => Exec['join_domain'],
    returns => [0, 204],
  }

  # Configure PBIS

  $pbis_conf = '/etc/pbis/pbis.conf'

  file { $pbis_conf:
    ensure  => file,
    owner   => root,
    group   => root,
    mode    => '0644',
    content => template('pbis/pbis.conf.erb'),
    require => Exec['join_domain'],
    notify  => Exec['clear_ad_cache'],
  }

  exec { 'configure_pbis':
    path        => ['/opt/pbis/bin'],
    command     => "config --file ${pbis_conf}",
    subscribe   => File[$pbis_conf],
    refreshonly => true,
  }

  exec { 'clear_ad_cache':
    path        => ['/opt/pbis/bin'],
    command     => 'ad-cache --delete-all',
    subscribe   => Exec['configure_pbis'],
    refreshonly => true,
  }
}
