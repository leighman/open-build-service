class ProjectController < ApplicationController 
  model :project, :package, :result

  before_filter :check_parameter_project, :except =>
    [ :list_all, :list_public, :list_my, :new, :save_new, :save, :index, :refresh_monitor,
      :toggle_watch ]

  def list_all
    projectlist = Project.find(:all).each_entry.sort do |a,b|  
      a.name.downcase <=> b.name.downcase
    end

    @project_pages, @projects = paginate_collection( projectlist )
  end

  def list_public
    logger.debug "inside list_public"
    projectlist = Project.find(:all).each_entry.sort do |a,b|  
      a.name.downcase <=> b.name.downcase 
    end

    projectlist.reject! do |p|
      p.name.to_s =~ /^home:/
    end
    
    @project_pages, @projects = paginate_collection( projectlist )
  end

  def list_my
    @projects = Project.find(:all).each_entry
    logger.debug "Have this session login: #{session[:login]}"
    @user ||= Person.find( :login => session[:login] )
    if @user.has_element? :watchlist
      #extract a list of project names and sort them case insensitive
      @watchlist = @user.watchlist.each_project.map {|p| p.name }.sort {|a,b| a.downcase <=> b.downcase }
    end
  end

  def remove_watched_project
    project = params[:project]
    @user ||= Person.find( session[:login] )
    logger.debug "removing watched project '#{project}' from user '#@user'"
    @user.remove_watched_project project
    @user.save

    @watchlist = @user.watchlist if @user.has_element? :watchlist

    render :partial => 'watch_list'
  end

  def new
    @project_name = params[:project]
    if @project_name =~ /home:(.*)/
      @project_title = "#$1's Home Project" 
    else
      @project_title = ""
    end
  end

  def show
    begin
      @project = Project.find( params[:project] )
    rescue ActiveXML::Transport::NotFoundError
      # create home project if none is there
      logger.debug "caught Transport::NotFoundError in ProjectController#show"
      home_project = "home:" + session[:login]
      if params[:project] == home_project
        flash[:note] = "Home project doesn't exist yet. You can create it now by entering some" +
          " descriptive data and press the 'Create Project' button."
        redirect_to :action => :new, :project => home_project
      else
        logger.debug "Project does not exist"
        flash[:error] = "Project #{params[:project]} doesn't exist."
        redirect_to :action => :list_public
      end
      return
    end

    #@project_name parameter needed for _watch_link partial
    @project_name = @project.name

    tmp = Hash.new
    @project.each_repository do |repo|
      repo.each_arch do |arch|
        tmp[arch.to_s] = 1
      end
    end

    @arch_list = tmp.keys.sort

    @packstatus = Packstatus.find( params[:project], :command => 'summaryonly' )
  end

  def save_new
    logger.debug( "save_new" )
  
    if !valid_project_name?( params[:name] )
      flash[:error] = "Invalid project name '#{params[:name]}'."
      redirect_to :action => "new"
    else
      #store project
      @project = Project.new( :name => params[:name] )

      @project.title.data.text = params[:title]
      @project.description.data.text = params[:description]
      @project.add_person :userid => session[:login], :role => 'maintainer'

      if @project.save
        flash[:note] = "Project '#{@project}' was created successfully"
      else
        flash[:error] = "Failed to save project '#{@project}'"
      end

      redirect_to :action => 'show', :project => params[:name]
    end
  end

  def edit
    @project = Project.find( params[:project] )
  end

  def trigger_rebuild
    @project = Project.find( params[:project] )
    if @project.save
      flash[:note] = "Triggered rebuild"
    else
      flash[:error] = "Failed to trigger rebuild"
    end
    redirect_to :action => 'show', :project => params[:project]
  end

  def save
    @project = Project.find( params[:project] )

    if ( !params[:title] )
      flash[:error] = "Title must not be empty"
      redirect_to :action => 'edit', :project => params[:project]
      return
    end

    @project.title.data.text = params[:title]
    @project.description.data.text = params[:description]

    if @project.save
      flash[:note] = "Project '#{@project}' was saved successfully"
    else
      flash[:error] = "Failed to save project '#{@project}'"
    end

    redirect_to :action => 'show', :project => @project
  end

  def add_target_simple
    @project = params[:project]
  end

  def add_target
    @platforms = Platform.find( :all ).each_entry.map {|p| p.name.to_s}

    #TODO: don't hardcode
    @priority_namespaces = %{
      Mandriva
      SUSE
      Fedora
      Debian
    }

    def @priority_namespaces.include_ns?(projname)
      nslist = projname.split(/:/)
      return false if nslist.length != 2
      return false unless self.include? nslist[0]
      return true
    end
    
    @platforms.sort! do |a,b|
      if @priority_namespaces.include_ns? a
        if @priority_namespaces.include_ns? b
          a.downcase <=> b.downcase
        else
          -1
        end
      else
        if @priority_namespaces.include_ns? b
          1
        else
          a.downcase <=> b.downcase
        end
      end
    end

    @project = Project.find( params[:project] )
    @targetname = params[:targetname]
    @platform = params[:platform]
  end

  def save_target
    @project = Project.find( params[:project] )
    platform = params[:platform]
    arch = params[:arch]
    targetname = params[:targetname]
    targetname = "standard" if not targetname or targetname.empty?

    if targetname =~ /\s/
      flash[:error] = "Target name may not contain spaces"
      redirect_to :action => :add_target, :project => @project, :targetname => targetname, :platform => platform
      return
    end

    @project.add_target :targetname => targetname, :platform => platform,
      :arch => arch

    if @project.save
      flash[:note] = "Target '#{platform}' was added successfully"
    else
      flash[:error] = "Failed to add target '#{platform}'"
    end

    redirect_to :action => :show, :project => @project
  end

  def remove_target
    if not params[:target]
      flash[:error] = "Target removal failed, no target selected!"
      redirect_to :action => :show, :project => params[:project]
    end

    @project = Project.find( params[:project] )
    @project.remove_target params[:target]

    if @project.save
      flash[:note] = "Target '#{params[:target]}' was removed"
    else
      flash[:error] = "Failed to remove target '#{params[:target]}'"
    end

    redirect_to :action => :show, :project => @project
  end

  def add_person
    @project = Project.find( params[:project] )
  end

  def save_person
    if not params[:userid]
      flash[:error] = "Login missing"
      redirect_to :action => :add_person, :project => params[:project], :role => params[:role]
      return
    end

    begin
      user = Person.find( :login => params[:userid] )
    rescue ActiveXML::NotFoundError
      flash[:error] = "Unknown user with id '#{params[:userid]}'"
      redirect_to :action => :add_person, :project => params[:project], :role => params[:role]
      return
    end
    
    logger.debug "found user: #{user.inspect}"
    
    @project = Project.find( params[:project] )
    @project.add_person( :userid => params[:userid], :role => params[:role] )

    if @project.save
      flash[:note] = "added user #{params[:userid]}"
    else
      flash[:error] = "Failed to add user '#{params[:userid]}'"
    end

    redirect_to :action => :show, :project => @project
  end

  def remove_person
    if not params[:userid]
      flash[:note] = "User removal aborted, no user id given!"
      redirect_to :action => :show, :project => params[:project]
      return
    end
    @project = Project.find( params[:project] )
    @project.remove_persons( :userid => params[:userid], :role => params[:role] )

    if @project.save
      flash[:note] = "removed user #{params[:userid]}"
    else
      flash[:error] = "Failed to remove user '#{params[:userid]}'"
    end

    redirect_to :action => :show, :project => params[:project]
  end

  def monitor
    @project = params[:project] 
    @packstatus = Packstatus.find( :project => @project )

    @repohash = Hash.new
    if not @packstatus.has_element? :packstatuslist
      @packstatus_unavailable = true
      return  
    end
    @packstatus.each_packstatuslist do |psl|
      @repohash[psl.repository] ||= Array.new
      @repohash[psl.repository] << psl.arch
    end

    @packagenames = Array.new
    @packstatus.packstatuslist.each_packstatus do |ps|
      @packagenames << ps.name
    end
    
    session[:monitor_project] = @project
    session[:monitor_repohash] = @repohash
    session[:monitor_packnames] = @packagenames
  end

  def refresh_monitor
    render :nothing unless session[:monitor_project] and
                           session[:monitor_repohash] and
                           session[:monitor_packnames]

    @project = session[:monitor_project]
    @repohash = session[:monitor_repohash]
    @packnames = session[:monitor_packnames]

    @packstatus = Packstatus.find( :project => @project )
    
    @status = Hash.new
    @packnames.each do |pack|
      @repohash.each do |repo,archlist|
        archlist.each do |arch|
          @status["#{pack}:#{repo}:#{arch}"] = @packstatus.status_for( pack, repo, arch )
        end
      end
    end

    render :layout => false
  end

  def toggle_watch
    unless session[:login]
      render :nothing => true
      return
    end
   
    @user = Person.find( :login => session[:login] ) unless @user
    @project_name = params[:project]
    
    if @user.watches? @project_name
      @user.remove_watched_project @project_name
    else
      @user.add_watched_project @project_name
    end

    @user.save

    render :partial => "watch_link"
  end

  private

  #filters
  
  def check_parameter_project
    if ( !params[:project] )
      flash[:error] = "Missing parameter 'project'"
      redirect_to :action => :list_public
    elsif !valid_project_name?( params[:project] )
      flash[:error] = "Invalid project name '#{params[:project]}'"
      redirect_to :action => :list_public
    end
  end

  def paginate_collection(collection, options = {})
    options[:page] = options[:page] || params[:page] || 1
    default_options = {:per_page => 20, :page => 1}
    options = default_options.merge options
    
    pages = Paginator.new self, collection.size, options[:per_page], options[:page]
    first = pages.current.offset
    last = [first + options[:per_page], collection.size].min
    slice = collection[first...last]
    return [pages, slice]
  end

end
