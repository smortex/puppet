require 'singleton'
require 'puppet/provider/package'

class PkgngVersionChecker
  include Singleton

  def latest_version(origin)
    updates[origin]
  end

  def updates
    return @updates if @updates

    Puppet.debug 'Listing packages with updates'
    @updates = {}
    pkg('version', '-voRUL=').lines.each do |line|
      if line =~ /^([^\s]+)\s.*\(remote has ([^)]+)\)/
        @updates[$1] = $2
        Puppet.debug "#{$1} is updatable to #{$2}"
      end
    end
    @updates
  end

  def pkg(*args)
    Puppet::Util::Execution.execute(['/usr/local/sbin/pkg', *args])
  end
end

Puppet::Type.type(:package).provide :pkgng, :parent => Puppet::Provider::Package do
  desc "A PkgNG provider for FreeBSD and DragonFly."

  commands :pkg => "/usr/local/sbin/pkg"

  confine :operatingsystem => [:freebsd, :dragonfly]

  defaultfor :operatingsystem => [:freebsd, :dragonfly]

  has_feature :versionable
  has_feature :upgradeable

  def self.get_query
    pkg(['query', '-a', '%n %v %o'])
  end

  def self.instances
    packages = []
    begin
      info = self.get_query

      unless info
        return packages
      end

      info.lines.each do |line|
        hash = parse_line(line)
        packages << new(hash)
      end

      return packages
    rescue Puppet::ExecutionFailure
      return []
    end
  end

  def self.prefetch(resources)
    packages = instances
    resources.each_key do |name|
      if provider = packages.find{|p| p.name == name or p.origin == name }
        resources[name].provider = provider
      end
    end
  end

  def self.parse_line(line)
    name, version, origin = line.chomp.split(' ', 3)
    latest_version  = PkgngVersionChecker.instance.latest_version(origin) || version

    {
      :ensure   => version,
      :name     => name,
      :provider => self.name,
      :origin   => origin,
      :version  => version,
      :latest   => latest_version
    }
  end

  def repo_tag_from_urn(urn)
    # extract repo tag from URN: urn:freebsd:repo:<tag>
    match = /^urn:freebsd:repo:(.+)$/.match(urn)
    raise ArgumentError urn.inspect unless match
    match[1]
  end

  def install
    source = resource[:source]
    source = URI(source) unless source.nil?

    # Ensure we handle the version
    case resource[:ensure]
    when true, false, Symbol
      installname = resource[:name]
    else
      # If resource[:name] is actually an origin (e.g. 'www/curl' instead of
      # just 'curl'), drop the category prefix. pkgng doesn't support version
      # pinning with the origin syntax (pkg install curl-1.2.3 is valid, but
      # pkg install www/curl-1.2.3 is not).
      if resource[:name] =~ /\//
        installname = resource[:name].split('/')[1] + '-' + resource[:ensure]
      else
        installname = resource[:name] + '-' + resource[:ensure]
      end
    end

    if not source # install using default repo logic
      args = ['install', '-qy', installname]
    elsif source.scheme == 'urn' # install from repo named in URN
      tag = repo_tag_from_urn(source.to_s)
      args = ['install', '-qy', '-r', tag, installname]
    else # add package located at URL
      args = ['add', '-q', source.to_s]
    end

    pkg(args)
  end

  def uninstall
    pkg(['remove', '-qy', resource[:name]])
  end

  def query
    begin
      output = pkg('query', '%n %v %o', resource[:name])
    rescue Puppet::ExecutionFailure
      return {:ensure => :absent, :status => 'missing', :name => resource[:name]}
    end

    self.class.parse_line(output)
  end

  def version
    @property_hash[:version]
  end

  # Upgrade to the latest version
  def update
    install
  end

  # Return the latest version of the package
  def latest
    debug "returning the latest #{@property_hash[:name].inspect} version #{@property_hash[:latest].inspect}"
    @property_hash[:latest]
  end

  def origin
    @property_hash[:origin]
  end

end
