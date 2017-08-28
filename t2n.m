function [out, origminterf,tree] = t2n(neuron,tree,options,exchfolder,server)
% t2n ("Trees toolbox to Neuron") is to generate and execute a NEURON
% simulation with the morphologies in tree, and parameters in the structure
% neuron. This is the main function.
% The output-file(s) of the NEURON function are read and transferred
% into the output variable out
% INPUTS
% neuron            t2n neuron structure with already defined mechanisms (see documentation)
% tree              tree cell array with morphologies (see documentation)
% options           string with optional arguments (can be concatenated):
%                   -w waitbar
%                   -d Debug mode (NEURON is opened and some parameters are set)
%                   -q quiet mode -> suppress output
%                   -o open all NEURON instances instead of running them in
%                      the background
%                   -m let T2N recompile the nrnmech.dll. Useful if a mod file was modified.
%                    For safety of compiled dlls, this option does not work when an explicit
%                    name of a dll was given via neuron.params.nrnmech!
%                   -cl cluster mode -> files are prepared to be executed
%                   on a cluster (see documentation for more information)
% exchfolder        (optional) relative name of folder where simulation data is
%                   saved. Default is t2n_exchfolder
% server            (only required in cluster mode) structure with
%                   server and server folder access information
%
% This code is based on an idea of Johannes Kasper, a former group-member
% in the Lab of Hermann Cuntz, Frankfurt.
%
% *****************************************************************************************************
% * This function is part of the T2N software package.                                                *
% * Copyright 2016, 2017 Marcel Beining <marcel.beining@gmail.com>                                    *
% *****************************************************************************************************


%%%%%%%%%%%%%%%%%%% CONFIGURATION %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
interf_file = 'neuron_runthis.hoc'; % the name of the main hoc file which will be written

%% check options and paths

t2npath = fileparts(which('t2n.m'));
modelFolder = pwd;

if nargin < 3 || isempty(options)
    options = '';
end
if ~isempty(strfind(options,'-d'))
    debug = 1;
else
    debug = 0;
end

%% check input
if ~exist('tree','var')
    error('No tree specified in input')
end
if ~exist('neuron','var') % if no neuron structure was given, create standard parameter set
    warning('No input about what to do was given! Standard test (HH + rectangle somatic stimulation) is used')
    neuron.pp{1}.IClamp = struct('node', 1, 'del',100,'dur',50,'amp',0.05);
    neuron.record{1}.cell = struct('node',1 ,'record', 'v');
    neuron.APCount{1} = {1,-30}; % {node, tresh}
    neuron.mech.all.pas = [];
    neuron.mech.soma.hh = [];
    neuron.mech.axon.hh = [];
end
[neuron,tree,usestreesof,nocell,nexchfolder] = t2n_checkinput(neuron,tree);
if ~exist('exchfolder','var')
    if ~isempty(nexchfolder)
        exchfolder = nexchfolder;
    else
        exchfolder = 't2n_exchange';
    end
end

if ~isempty(strfind(options,'-cl')) % server mode
    nrn_path = server.modelfolder;
    if ~isfield(server,'walltime') || numel(server.walltime) ~=3
        server.walltime = [5 0 0];
        warning('Server walltime not specified correctly (1 by 3 vector in server.walltime). Walltime set to 5 hours');
    end
    if ~isfield(server,'memory') || numel(server.memory) ~=1
        server.memory = 1;
        warning('Max memory per node not specified correctly (1 scalar [GB] in server.memory). Max memory set to 1GB');
    end
    server.softwalltime = sum(server.walltime .* [3600,60,1])-30; %subtract 30 sec
    server.softwalltime = floor([server.softwalltime/3600,rem(server.softwalltime,3600)/60,rem(server.softwalltime,60)]);
    server.envstr = '';
    server.qfold = '';
    if isfield(server,'env') && isstruct(server.env)
        envnames = fieldnames(server.env);
        for v = 1:numel(envnames)
            server.envstr = [server.envstr,'setenv ',envnames{v},' ',server.env.(envnames{v}),'; '];
        end
        if isfield(server.env,'SGE_ROOT') && isfield(server.env,'SGE_ARCH')
            server.qfold = sprintf('%s/bin/%s/',server.env.SGE_ROOT,server.env.SGE_ARCH);
        end
    end
else
    nrn_path = modelFolder;
end
nrn_path = regexprep(nrn_path,'\\','/');
if strcmp(nrn_path(end),'/') % remove "/" from path
    nrn_path = nrn_path(1:end-1);
end

%% connect to server
if strfind(options,'-cl') % server mode
    if ~exist('server','var')
        error('No access data provided for Cluster server. Please specify in server')
    else
        if isfield(server,'connect')
            
        else
            if  exist('sshj-master/sshj-0.0.0-no.git.jar','file')% exist('ganymed-ssh2-build250/ganymed-ssh2-build250.jar','file')
                sshjfolder = fileparts(which('sshj-master/sshj-0.0.0-no.git.jar'));
                javaaddpath(fullfile(sshjfolder,'sshj-0.0.0-no.git.jar'));%javaaddpath(which('ganymed-ssh2-build250/ganymed-ssh2-build250.jar'));
                javaaddpath(fullfile(sshjfolder,'bcprov-ext-jdk15on-156.jar'));
                javaaddpath(fullfile(sshjfolder,'bcpkix-jdk15on-1.56.jar'));
                javaaddpath(fullfile(sshjfolder,'slf4j-1.7.23'));
            else
                try
                    sshfrommatlabinstall(1)
                catch
                    error('Could not find the ganymed ssh zip file')
                end
            end
            server.connect = sshfrommatlab(server);
        end
        if ~isfield(server,'modelfolder')
            error('No folder on Server specified, please specify under server.modelfolder')
        end
    end
end


%% check for exchange folder (folder where files between Matlab and NEURON
% are exchanged)

if strfind(options,'-cl')
    nrn_exchfolder = fullfile(server.modelfolder,exchfolder);
else
    nrn_exchfolder = fullfile(modelFolder,exchfolder);
end

nrn_exchfolder = regexprep(nrn_exchfolder,'\\','/');


%% Check if NEURON software exists at the given path
if ~isempty(strfind(options,'-cl'))
    [~, outp] = sshfrommatlabissue(server.connect,'module avail');
    server.neuron = regexpi(outp.StdErr,'neuron/\d{1,2}\.\d{1,2}\s','match');  % available modules are reported to errorStream..dunno why
    %     server.envstr = [server.envstr, sprintf('module load %s; ',outp{1})];  % load first found neuron version
    fprintf('Available neuron modules found:\n%s\nChoosing %s',sprintf('%s',server.neuron{:}),server.neuron{1})
elseif ispc
    askflag = 0;
    if exist(fullfile(t2npath,'nrniv_win.txt'),'file')
        fid = fopen(fullfile(t2npath,'nrniv_win.txt'),'r');
        nrnivPath = fread(fid,'*char')';
        fclose(fid);
        if exist(nrnivPath,'file') ~= 2
            askflag = 1;
        end
    else
        askflag = 1;
    end
    if askflag
        [filename,pathname] = uigetfile('.exe',sprintf('No NEURON software found under "%s"! Please give enter path to nrniv.exe',nrnivPath));
        nrnivPath = fullfile(pathname,filename);
        fid = fopen(fullfile(t2npath,'nrniv_win.txt'),'w');
        fprintf(fid,strrep(nrnivPath,'\','/'));
        fclose(fid);
    end
else
    [~,outp] = system('which nrniv');
    if isempty(outp)
        if ismac
            error('NEURON software (nrniv) not found on this Mac! Either not installed correctly or Matlab was not started from Terminal')
        else
            error('NEURON software (nrniv) not found on this Linux machine! Check correct installation')
        end
    end
    nrnivPath = outp;
end


%% check for standard hoc files in the model folder and copy them if not existing
if ~exist(fullfile(modelFolder,'lib_genroutines'),'dir')
    mkdir(modelFolder,'lib_genroutines')
    warning('non-existent folder lib_genroutines created')
end
if ~exist(fullfile(modelFolder,'lib_genroutines/fixnseg.hoc'),'file')
    copyfile(fullfile(t2npath,'src','fixnseg.hoc'),fullfile(modelFolder,'lib_genroutines/fixnseg.hoc'))
    disp('fixnseg.hoc copied to model folder')
end
if ~exist(fullfile(modelFolder,'lib_genroutines/genroutines.hoc'),'file')
    copyfile(fullfile(t2npath,'src','genroutines.hoc'),fullfile(modelFolder,'lib_genroutines/genroutines.hoc'))
    disp('genroutines.hoc copied to model folder')
end
if ~exist(fullfile(modelFolder,'lib_genroutines/pasroutines.hoc'),'file')
    copyfile(fullfile(t2npath,'src','pasroutines.hoc'),fullfile(modelFolder,'lib_genroutines/pasroutines.hoc'))
    disp('pasroutines.hoc copied to model folder')
end

%% create the local and server exchange folder
if exist(exchfolder,'dir') == 0
    mkdir(exchfolder);
end
if strfind(options,'-cl')
    localfilename = {};
    mechflag = false;
    [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('mkdir %s',server.modelfolder));  % check if mainfolder exists
    [server.connect,outp] = sshfrommatlabissue(server.connect,sprintf('ls %s',server.modelfolder));  % check if mainfolder exists
    if isempty(regexp(outp.StdOut,'lib_genroutines', 'once'))
        [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('mkdir %s/lib_genroutines',server.modelfolder));
        fils = dir(fullfile(modelFolder,'lib_genroutines/'));  % get files from folder
        localfilename = cat(2,localfilename,fullfile(modelFolder,'lib_genroutines',{fils(~cellfun(@(x) strcmp(x,'.')|strcmp(x,'..'),{fils.name})).name})); % find all files
    end
    if isempty(regexp(outp.StdOut,'morphos/hocs', 'once'))
        [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('mkdir %s/%s',server.modelfolder,'morphos/hocs'));
        fils = dir(fullfile(modelFolder,'morphos/hocs'));  % get files from folder
        localfilename = cat(2,localfilename,fullfile(modelFolder,'morphos/hocs',{fils(cellfun(@(x) ~isempty(regexpi(x,'.hoc')),{fils.name})).name})); % find all hoc files
    end
    if isempty(regexp(outp.StdOut,'lib_mech','ONCE'))
        [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('mkdir %s/lib_mech',server.modelfolder));
        fils = dir(fullfile(modelFolder,'lib_mech/'));
        localfilename = cat(2,localfilename,fullfile(modelFolder,'lib_mech',{fils(cellfun(@(x) ~isempty(regexpi(x,'.mod')),{fils.name})).name}));  % find all mod files
        mechflag = true;
    end
    if isempty(regexp(outp.StdOut,'lib_custom','ONCE'))
        [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('mkdir %s/lib_custom',server.modelfolder));
        fils = dir(fullfile(modelFolder,'lib_custom/'));
        localfilename = cat(2,localfilename,fullfile(modelFolder,'lib_custom',{fils(~cellfun(@(x) strcmp(x,'.')|strcmp(x,'..'),{fils.name})).name})); %find all files
    end
    if ~isempty(localfilename)
        localfilename = regexprep(localfilename,'\\','/');
        remotefilename = regexprep(localfilename,modelFolder,server.modelfolder);
        sftpfrommatlab(server.user,server.host,server.pw,localfilename,remotefilename);
        
    end
    if mechflag  % compile mod files
        [server.connect,outp] = sshfrommatlabissue(server.connect,sprintf('cd %s/lib_mech;module load %s; nrnivmodl',server.modelfolder,server.neuron{1}));
        display(outp.StdOut)
        pause(5)
    end
    [server.connect,outp] = sshfrommatlabissue(server.connect,sprintf('cd %s/lib_mech/;ls -d */',server.modelfolder));
    server.nrnmech = regexprep(fullfile(server.modelfolder,'lib_mech',outp.StdOut(1:regexp(outp.StdOut,'/')-1),'.libs','libnrnmech.so'),'\\','/'); % there should only be one folder in it
    [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('rm -rf %s',nrn_exchfolder));
    [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('mkdir %s',nrn_exchfolder));
end


%% initialize basic variables
noutfiles = 0;          % counter for number of output files
readfiles = cell(0);    % cell array that stores information about output files

out = cell(numel(neuron),1);

origminterf = cell(numel(tree),1);
for t = 1:numel(tree)
    if ~isfield(tree{t},'artificial')
        origminterf{t} = load(fullfile(modelFolder,'morphos','hocs',sprintf('%s_minterf.dat',tree{t}.NID)));
    end
end


%% start writing hoc file
spines_flag = false(numel(neuron),1);
minterf = cell(numel(tree),1);
for n = 1:numel(neuron)
    makenewrect = true;
    refPar = t2n_getref(n,neuron,'params');
    refM = t2n_getref(n,neuron,'mech');
    refPP = t2n_getref(n,neuron,'pp');
    refC = t2n_getref(n,neuron,'con');
    refR = t2n_getref(n,neuron,'record');
    refP = t2n_getref(n,neuron,'play');
    refAP = t2n_getref(n,neuron,'APCount');
    for t = 1:numel(neuron{refM}.mech)   % check if any region of any tree has the spines mechanism
        if ~isempty(neuron{refM}.mech{t})
            fields = fieldnames(neuron{refM}.mech{t});
            for f = 1:numel(fields)
                if any(strcmpi(fieldnames(neuron{refM}.mech{t}.(fields{f})),'spines'))
                    spines_flag(n) = true;
                    break
                end
            end
            if spines_flag(n)
                break
            end
        end
    end
    
    if ~isfield(neuron{n},'custom')
        neuron{n}.custom = {};
    end
    if strfind(options,'-d')
        tim = tic;
    end
    for tt = 1:numel(tree(neuron{n}.tree))
        if ~isfield(tree{neuron{n}.tree(tt)},'artificial')
            minterf{neuron{n}.tree(tt)} = t2n_make_nseg(tree{neuron{n}.tree(tt)},origminterf{neuron{n}.tree(tt)},neuron{refPar}.params,neuron{refM}.mech{neuron{n}.tree(tt)});
        end
    end
    access = [find(~cellfun(@(y) isfield(y,'artificial'),tree(neuron{n}.tree)),1,'first'), 1];      % std accessing first non-artificial tree at node 1
    thisfolder = sprintf('sim%d',n);
    
    if exist(fullfile(exchfolder,thisfolder),'dir') == 0
        mkdir(fullfile(exchfolder,thisfolder));
    end
    if exist(fullfile(exchfolder,thisfolder,'iamrunning'),'file')
        answer = questdlg(sprintf('Error!\n%s seems to be run by another Matlab instance!\nOverwriting might cause errorneous output!\nIf you are sure that there is no simulation running, we can continue and overwrite. Are you sure? ',fullfile(exchfolder,thisfolder)),'Overwrite unfinished simulation','Yes to all','Yes','No (Cancel)','No (Cancel)');
        switch answer
            case 'Yes'
                % iamrunning file is kept and script goes on...
            case 'Yes to all'  % delete all iamrunning files in that exchfolder except from the current simulation
                folders = dir(exchfolder);
                for f = 1:numel(folders) % ignore first two as these are . and ..
                    if ~isempty(strfind(folders(f).name,'sim')) && ~strcmp(folders(f).name,thisfolder) && exist(fullfile(exchfolder,folders(f).name,'iamrunning'),'file')
                        delete(fullfile(exchfolder,folders(f).name,'iamrunning'))
                    end
                end
            otherwise
                error('T2N aborted')
        end
    else
        ofile = fopen(fullfile(exchfolder,thisfolder,'iamrunning') ,'wt');   %open morph hoc file in write modus
        fclose(ofile);
    end
    % delete the readyflag and log files if they exist
    if exist(fullfile(exchfolder,thisfolder,'readyflag'),'file')
        delete(fullfile(exchfolder,thisfolder,'readyflag'))
    end
    if exist(fullfile(exchfolder,thisfolder,'ErrorLogFile.txt'),'file')
        delete(fullfile(exchfolder,thisfolder,'ErrorLogFile.txt'))
    end
    if exist(fullfile(exchfolder,thisfolder,'NeuronLogFile.txt'),'file')
        delete(fullfile(exchfolder,thisfolder,'NeuronLogFile.txt'))
    end
    if ~isempty(strfind(options,'-cl'))
        [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('mkdir %s/%s',nrn_exchfolder,thisfolder));
    end
    
    %% write interface hoc
    
    nfile = fopen(fullfile(exchfolder,thisfolder,interf_file) ,'wt');   %open resulting hoc file in write modus
    
    fprintf(nfile,'// ***** This is a NEURON hoc file automatically created by the Matlab-NEURON interface T2N. *****\n');
    fprintf(nfile,'// ***** Copyright by Marcel Beining, Clinical Neuroanatomy, Goethe University Frankfurt*****\n\n');
    %initialize variables in NEURON
    fprintf(nfile,'// General variables: i, CELLINDEX, debug_mode, accuracy\n\n');
    
    fprintf(nfile,'// ***** Initialize Variables *****\n');
    fprintf(nfile,'strdef tmpstr,simfold // temporary string object\nobjref f\n');
    fprintf(nfile,'objref pnm,pc,nil,cvode,strf,tvec,cell,cellList,pp,ppList,con,conList,nilcon,nilconList,rec,recList,rect,rectList,playt,playtList,play,playList,APCrec,APCrecList,APC,APCList,APCcon,APCconList,thissec,thisseg,thisval,maxRa,maxcm \n cellList = new List() // comprises all instances of cell templates, also artificial cells\n ppList = new List() // comprises all Point Processes of any cell\n conList = new List() // comprises all NetCon objects\n recList = new List() //comprises all recording vectors\n rectList = new List() //comprises all time vectors of recordings\n playtList = new List() //comprises all time vectors for play objects\n playList = new List() //comprises all vectors played into an object\n APCList = new List() //comprises all APC objects\n APCrecList = new List() //comprises all APC recording vectors\n nilconList = new List() //comprises all NULL object NetCons\n cvode = new CVode() //the Cvode object\n thissec = new Vector() //for reading range variables\n thisseg = new Vector() //for reading range variables\n thisval = new Vector() //for reading range variables\n\n');% maxRa = new Vector() //for reading range variables\n maxcm = new Vector() //for reading range variables\n\n');%[',numel(tree),']\n'  ;
    fprintf(nfile,sprintf('\nchdir("%s") // change directory to main simulation folder \n',nrn_path));
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Define some basic parameters *****\n');
    fprintf(nfile,sprintf('debug_mode = %d\n',debug) );
    if isfield(neuron{refPar}.params,'accuracy')
        fprintf(nfile,sprintf('accuracy = %d\n',neuron{refPar}.params.accuracy) );
    else
        fprintf(nfile,'accuracy = 0\n' );
    end
    fprintf(nfile,'strf = new StringFunctions()\n');
    if neuron{refPar}.params.cvode
        fprintf(nfile,'cvode.active(1)\n');
        if neuron{refPar}.params.use_local_dt
            fprintf(nfile,'io = cvode.use_local_dt(1)\n');
        end
    else
        fprintf(nfile,'io = cvode.active(0)\n');
        fprintf(nfile,sprintf('tvec = new Vector()\ntvec = tvec.indgen(%f,%f,%f)\n',neuron{refPar}.params.tstart,neuron{refPar}.params.tstop,neuron{refPar}.params.dt));
        if refPar == n  % only write tvec if parameters are not referenced from another sim
            fprintf(nfile,'f = new File()\n');      %create a new filehandle
            fprintf(nfile,sprintf('io = f.wopen("%s//%s//tvec.dat")\n',exchfolder,thisfolder)  );  % open file for this time vector with write perm.
            fprintf(nfile,sprintf('io = tvec.printf(f,"%%%%-20.10g\\\\n")\n') );    % print the data of the vector into the file
            fprintf(nfile,'io = f.close()\n');
        end
    end
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Load standard libraries *****\n');
    if isfield(neuron{refPar}.params,'nrnmech')
        if iscell(neuron{refPar}.params.nrnmech)
            for c = 1:numel(neuron{refPar}.params.nrnmech)
                if ~exist(fullfile(modelFolder,'lib_mech',neuron{refPar}.params.nrnmech{c}),'file')
                    error('File %s is not existent in folder lib_mech',neuron{refPar}.params.nrnmech{c})
                end
                fprintf(nfile,sprintf('io = nrn_load_dll("lib_mech/%s")\n',neuron{refPar}.params.nrnmech{c}));
            end
        else
            if ~exist(fullfile(modelFolder,'lib_mech',neuron{refPar}.params.nrnmech),'file')
                error('File %s is not existent in folder lib_mech',neuron{refPar}.params.nrnmech)
            end
            fprintf(nfile,sprintf('io = nrn_load_dll("lib_mech/%s")\n',neuron{refPar}.params.nrnmech));
        end
    else
        if exist(fullfile(modelFolder,'lib_mech'),'dir')
            if ispc
                if ~exist(fullfile(modelFolder,'lib_mech','nrnmech.dll'),'file') || ~isempty(strfind(options,'-m'))  % check for existent file, otherwise compile dll
                    nrn_installfolder = regexprep(fileparts(fileparts(nrnivPath)),'\\','/');
                    tstr = sprintf('cd "%s" && %s/mingw/bin/sh "%s/mknrndll.sh" %s',[nrn_path,'/lib_mech'],nrn_installfolder, regexprep(t2npath,'\\','/'), ['/',regexprep(nrn_installfolder,':','')]);
                    [~,cmdout] = system(tstr);
                    if isempty(strfind(cmdout,'nrnmech.dll was built successfully'))
                        error('File nrnmech.dll was not found in lib_mech and compiling it with mknrndll failed! Check your mod files and run mknrndll manually')
                    else
                        disp('nrnmech.dll compiled from mod files in folder lib_mech')
                    end
                    t2n_rename_nrnmech()  % delete the o and c files
                end
                fprintf(nfile,'nrn_load_dll("lib_mech/nrnmech.dll")\n');
            else
                mechfold = dir(fullfile(modelFolder,'lib_mech','x86_*'));
                if isempty(mechfold) || ~isempty(strfind(options,'-m'))  % check for existent file, otherwise compile dll
                    [~,outp] = system(sprintf('cd "%s/lib_mech";nrnivmodl',modelFolder));
                    if ~isempty(regexp(outp,'Successfully','ONCE'))
                        disp('nrn mechanisms compiled from mod files in folder lib_mech')
                    else
                        error('There was an error during compiling of mechanisms:\n\n%s',outp)
                    end
                end
            end
        else
            warning('No folder "lib_mech" found in your model directory and no nrnmech found to load in neuron{refP}.params.nrnmech. Only insertion of standard mechanisms (pas,hh,IClamp,AlphaSynapse etc.) possible.')
        end
    end
    
    if ~isempty(strfind(options,'-o'))
        fprintf(nfile,'io = load_file("nrngui.hoc")\n');     % load the NEURON GUI
    else
        fprintf(nfile,'io = load_file("stdgui.hoc")\n');     % ony load other standard procedures
    end
    fprintf(nfile,sprintf('simfold = "%s/%s"\n',nrn_exchfolder,sprintf('sim%d',n))); % das passt so!
    fprintf(nfile, sprintf('io = xopen("lib_genroutines/fixnseg.hoc")\n') );
    fprintf(nfile, sprintf('io = xopen("lib_genroutines/genroutines.hoc")\n') );
    fprintf(nfile, sprintf('io = xopen("lib_genroutines/pasroutines.hoc")\n') );
    fprintf(nfile,'\n\n');
    if neuron{refPar}.params.parallel
        [GIDs,neuron,mindelay] = t2n_getGIDs(neuron{n},tree,neuron{n}.tree);
        mindelay = max(mindelay,neuron{refPar}.dt);  % make mindelay at least the size of dt
        fprintf(nfile,'// ***** Initialize parallel manager *****\n');
        fprintf(nfile,'pnm = new ParallelNetManager(%d)\npc = pnm.pc\n\n\n',numel(GIDs));
        for in = 1:numel(GIDs)
            fprintf(nfile,'pc.set_gid2node(%d, %d)\n',GIDs(in).gid,rem(GIDs(in).cell-1,neuron{refPar}.params.parallel));  % distribute the gids in such a way that all sections/pps of one cell are on the same host, and do roundrobin for each cell
        end
    end
    fprintf(nfile,'// ***** Load custom libraries *****\n');
    if ~isempty(neuron{n}.custom)
        for c = 1:size(neuron{n}.custom,1)
            if strcmpi(neuron{n}.custom{c,2},'start')
                if strcmp(neuron{n}.custom{c,1}(end-4:end),'.hoc')   %check for hoc ending
                    if exist(fullfile(nrn_path,'lib_custom',neuron{n}.custom{c,1}),'file')
                        fprintf(nfile,sprintf('io = load_file("lib_custom/%s")\n',neuron{n}.custom{c,1}));
                    else
                        fprintf('File "%s" does not exist',neuron{n}.custom{c,1})
                    end
                else
                    fprintf(nfile,neuron{n}.custom{c,1});  % add string as custom neuron code
                end
            end
        end
    end
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Load cell morphologies and create artificial cells *****\n');
    fprintf(nfile,sprintf('io = xopen("%s/%s/init_cells.hoc")\n',nrn_exchfolder,sprintf('sim%d',usestreesof(n)))); % das passt so!
    
    fprintf(nfile,sprintf('\n\nchdir("%s/%s") // change directory to folder of simulation #%d \n',exchfolder,thisfolder,n));
    fprintf(nfile,'\n\n');
    
    if ~isnan(refM)
        fprintf(nfile,'// ***** Load mechanisms and adjust nseg *****\n');
        if refM~=n
            fprintf(nfile,sprintf('io = load_file("%s/%s/init_mech.hoc")\n',nrn_exchfolder,sprintf('sim%d',refM)) );
        else
            fprintf(nfile,'io = xopen("init_mech.hoc")\n' );
        end
        fprintf(nfile,'\n\n');
    end
    
    
    if ~isnan(refPP)
        fprintf(nfile,'// ***** Place Point Processes *****\n');
        if refPP~=n
            fprintf(nfile,sprintf('io = load_file("%s/%s/init_pp.hoc")\n',nrn_exchfolder,sprintf('sim%d',refPP)) );
        else
            fprintf(nfile,'io = xopen("init_pp.hoc")\n' );
        end
        fprintf(nfile,'\n\n');
    end
    
    if ~isnan(refC)
        fprintf(nfile,'// ***** Define Connections *****\n');
        if refC~=n
            fprintf(nfile,sprintf('io = load_file("%s/%s/init_con.hoc")\n',nrn_exchfolder,sprintf('sim%d',refC)) );
        else
            fprintf(nfile,'io = xopen("init_con.hoc")\n' );
        end
        fprintf(nfile,'\n\n');
    end
    
    
    
    
    
    if ~isnan(refR) || ~isnan(refAP)
        fprintf(nfile,'// ***** Define recording sites *****\n');
        if refR~=n && refAP~=n && refR==refAP  % if both reference to the same other sim, use this sim
            fprintf(nfile,sprintf('io = load_file("%s/%s/init_rec.hoc")\n',nrn_exchfolder,sprintf('sim%d',refR)) );
        else  % else write an own file
            fprintf(nfile,'io = xopen("init_rec.hoc")\n' );
        end
        fprintf(nfile,'\n\n');
    end
    
    
    if ~isnan(refP)
        fprintf(nfile,'// ***** Define vector play sites *****\n');
        if refP~=n
            fprintf(nfile,sprintf('io = load_file("%s/%s/init_play.hoc")\n',nrn_exchfolder,sprintf('sim%d',refP)) );
        else
            fprintf(nfile,'io = xopen("init_play.hoc")\n' );
        end
    end
    
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Last settings *****\n');
    if isfield(neuron{refPar}.params,'celsius')
        if neuron{refPar}.params.q10 == 1
            fprintf(nfile,'\n\nobjref q10\nq10 = new Temperature()\n' ) ;
            fprintf(nfile,sprintf('io = q10.correct(%g)\n\n',neuron{refPar}.params.celsius) ) ;
        else
            fprintf(nfile,sprintf('celsius = %g\n\n',neuron{refPar}.params.celsius) ) ;
            
        end
    end
    if spines_flag(n)
        fprintf(nfile,'addsurf_spines()\n');
    end
    fprintf(nfile,sprintf('tstart = %f\n',neuron{refPar}.params.tstart));   %set tstart
    fprintf(nfile,sprintf('tstop = %f + %f //advances one more step due to roundoff errors for high tstops\n',neuron{refPar}.params.tstop,neuron{refPar}.params.dt));   %set tstop
    fprintf(nfile,sprintf('dt = %f\n',neuron{refPar}.params.dt));         % set dt
    fprintf(nfile,sprintf('steps_per_ms = %f\n',1/neuron{refPar}.params.dt));         % set steps per ms to avois changing dt on reinit
    if isfield(neuron{refPar}.params,'v_init')
        fprintf(nfile,sprintf('v_init = %f\n',neuron{refPar}.params.v_init));
    end
    fprintf(nfile,sprintf('prerun = %d\n',neuron{refPar}.params.prerun));
    if numel(access) > 1 % if there is any non-artificial cell defined
        fprintf(nfile,sprintf('access cellList.o(%d).allregobj.o(%d).sec\n',access(1)-1,minterf{neuron{n}.tree(access(1))}(access(2),2)) );
    end
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Include prerun or standard run replacing custom code *****\n');
    if ~isempty(neuron{n}.custom)
        for c = 1:size(neuron{n}.custom,1)
            if strcmpi(neuron{n}.custom{c,2},'mid')
                if strcmp(neuron{n}.custom{c,1}(end-4:end),'.hoc')   %check for hoc ending
                    if exist(fullfile(nrn_path,'lib_custom',neuron{n}.custom{c,1}),'file')
                        fprintf(nfile,sprintf('io = load_file("%s/lib_custom/%s")\n',nrn_path,neuron{n}.custom{c,1}));
                    else
                        fprintf('File "%s" does not exist',neuron{n}.custom{c,1})
                    end
                else
                    fprintf(nfile,neuron{n}.custom{c,1});  % add string as custom neuron code
                end
            end
        end
    end
    if neuron{refPar}.params.parallel
        fprintf(nfile,'pc.barrier()\n');
    end
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Run NEURON *****\n');
    
    if ~neuron{refPar}.params.skiprun
        if neuron{refPar}.params.parallel
            fprintf(nfile,'pc.set_maxstep(%d)\npc.solve(tstop)\n',mindelay);   %!%!%!%! change this! neuron{n}.con...... %!%! also include prerun
        else
            fprintf(nfile,'init()\n');  % this needs to be modified later since v_init might be restarted
            fprintf(nfile,'run()\n');         % directly run the simulation
        end
    else
        fprintf(nfile,'// Run is skipped due to custom code\n');
    end
    
    fprintf(nfile,'\n\n');
    fprintf(nfile,'io = xopen("save_rec.hoc")\n' );
    
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Include finishing custom code *****\n');
    if ~isempty(neuron{n}.custom)
        for c = 1:size(neuron{n}.custom,1)
            if strcmpi(neuron{n}.custom{c,2},'end')
                if strcmp(neuron{n}.custom{c,1}(end-4:end),'.hoc')   %check for hoc ending
                    if exist(fullfile(nrn_path,'lib_custom',neuron{n}.custom{c,1}),'file')
                        fprintf(nfile,sprintf('io = load_file("%s/lib_custom/%s")\n',nrn_path,neuron{n}.custom{c,1}));
                    else
                        fprintf('File "%s" does not exist',neuron{n}.custom{c,1})
                    end
                else
                    fprintf(nfile,neuron{n}.custom{c,1});  % add string as custom neuron code
                end
            end
        end
    end
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// ***** Make Matlab notice end of simulation *****\n');
    fprintf(nfile,'f = new File()\n');       %create a new filehandle
    fprintf(nfile,'io = f.wopen("readyflag")\n' );       % create the readyflag file
    fprintf(nfile,'io = f.close()\n');   % close the filehandle
    if isempty(strfind(options,'-o'))
        fprintf(nfile,'quit()\n');  % exit NEURON if it was defined so in the parameters
    end
    
    fprintf(nfile,'\n\n');
    fprintf(nfile,'// *-*-*-*-* END *-*-*-*-*\n');
    
    fclose(nfile);
    
    
    %% write init_cells.hoc
    
    if usestreesof(n) == n  % write only if morphologies are not referenced to other sim init_cell.hoc
        ofile = fopen(fullfile(exchfolder,thisfolder,'init_cells.hoc') ,'wt');   %open morph hoc file in write modus
        fprintf(ofile,'\n\n');
        fprintf(ofile,'// ***** Load cell morphology templates and create artificial cells *****\n');
        templates = cell(0);
        for tt = 1:numel(neuron{n}.tree)
            % load templates generated by neuron_template_tree, create one
            % instance of them and add them to the cellList
            if neuron{refPar}.params.parallel
                fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
            end
            if ~any(strcmp(templates,tree{neuron{n}.tree(tt)}.NID))
                fprintf(ofile,'io = xopen("%s//%s.hoc")\n','morphos/hocs',tree{neuron{n}.tree(tt)}.NID );
                templates = cat(1,templates,tree{neuron{n}.tree(tt)}.NID);
            end
            fprintf(ofile,'cell = new %s()\n', tree{neuron{n}.tree(tt)}.NID );
            fields = fieldnames( tree{neuron{n}.tree(tt)});
            fields = setdiff(fields,{'NID','artificial'});  % get all fields that are not "NID" or "artificial". These should be parameters to define
            for f = 1:numel(fields)
                if ischar(tree{neuron{n}.tree(tt)}.(fields{f})) && regexpi(tree{neuron{n}.tree(tt)}.(fields{f}),'^(.*)$')  % check if this is a class/value pair, then use the () instead of =
                    fprintf(ofile, 'cell.cell.%s%s\n',fields{f}, tree{neuron{n}.tree(tt)}.(fields{f}));
                else
                    fprintf(ofile, 'cell.cell.%s = %g\n',fields{f}, tree{neuron{n}.tree(tt)}.(fields{f}));
                end
            end
            if neuron{refPar}.params.parallel
                fprintf(ofile,'}else{cell = nil}\n');
            end
            fprintf(ofile, 'io = cellList.append(cell)\n');
            
        end
        fprintf(ofile, 'objref cell\n');
        
        fprintf(ofile,'\n\n');
        
        fclose(ofile);
    elseif exist(fullfile(exchfolder,thisfolder,'init_cells.hoc'),'file')
        delete(fullfile(exchfolder,thisfolder,'init_cells.hoc'));
    end
    
    %% write init_mech.hoc
    
    if t2n_getref(n,neuron,'mech') == n     %rewrite only if mechanism is not taken from previous sim
        rangestr = '';
        ofile = fopen(fullfile(exchfolder,thisfolder,'init_mech.hoc') ,'wt');   %open morph hoc file in write modus
        fprintf(ofile,'\n\n');
        fprintf(ofile,'// ***** Insert mechanisms *****\n');
        if isfield(neuron{n},'mech')
            flag_strion_all = false(numel(neuron{n}.tree),1);
            strion_all = cell(numel(neuron{n}.tree),1);
            flag_strnseg_all = false(numel(neuron{n}.tree),1);
            strnseg_all = cell(numel(neuron{n}.tree),1);
            strion_reg = cell(numel(neuron{n}.tree),1);
            flag_strion_reg = cell(numel(neuron{n}.tree),1);
            strnseg_reg = cell(numel(neuron{n}.tree),1);
            flag_strnseg_reg = cell(numel(neuron{n}.tree),1);
            for tt = 1:numel(neuron{n}.tree)
                t = neuron{n}.tree(tt);
                if numel(neuron{n}.mech) >= t && ~isempty(neuron{n}.mech{t})   && ~isfield(tree{neuron{n}.tree(tt)},'artificial')    % if a mechanism is defined for this tree
                    if isstruct(neuron{n}.mech{t})          % input must be a structure
                        fields = fieldnames(neuron{n}.mech{t});
                    else
                        continue
                    end
                    if neuron{refPar}.params.parallel
                        fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                    end
                    if any(strcmpi(fields,'all'))
                        str = sprintf('forsec cellList.o(%d).allreg {\n',tt-1);   %neuron:go through this region
                        strion_all{tt} = sprintf('forsec cellList.o(%d).allreg {\n',tt-1);   %neuron:go through this region
                        
                        strnseg_all{tt} = sprintf('forsec cellList.o(%d).allreg {\n',tt-1);   %neuron:go through this region
                        
                        mechs = fieldnames(neuron{n}.mech{t}.all);                % mechanism names are the fieldnames in the structure
                        if any(strcmp(mechs,'nseg'))
                            mechs = setdiff(mechs,'nseg');
                            strnseg_all{tt} = sprintf('%snseg = %d\n',strnseg_all{tt},neuron{n}.mech{t}.all.nseg);   %neuron: define values
                            flag_strnseg_all(tt) = true;
                        end
                        for m = 1:numel(mechs)      % loop through mechanisms
                            str = sprintf('%sinsert %s\n',str,mechs{m});        % neuron:insert this mechanism
                            if ~isempty(neuron{n}.mech{t}.all.(mechs{m}))
                                mechpar = fieldnames(neuron{n}.mech{t}.all.(mechs{m}));
                                for p = 1:numel(mechpar)  % loop through mechanism parameters
                                    if strcmpi(mechpar{p},'cm') || strcmpi(mechpar{p},'Ra') || (~isempty(strfind(mechs{m},'_ion')) &&  (numel(mechpar{p}) <= strfind(mechs{m},'_ion') || (numel(mechpar{p}) > strfind(mechs{m},'_ion') && ~strcmp(mechpar{p}(strfind(mechs{m},'_ion')+1),'0'))))       %if mechanism is an ion or passive cm/Ra, leave out mechansim suffix
                                        if ~isempty(strfind(mechs{m},'_ion')) && strcmpi(mechpar{p},'style')
                                            if numel(neuron{n}.mech{t}.all.(mechs{m}).(mechpar{p})) ~= 5
                                                for nn = 1:numel(neuron)
                                                    delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                                                end
                                                error('Error! Style specification of ion "%s" should be 5 numbers (see NEURON or t2n documentation)',mechs{m})
                                            end
                                            strion_all{tt} = sprintf('%sion_style("%s",%d,%d,%d,%d,%d)\n',strion_all{tt},mechs{m},neuron{n}.mech{t}.all.(mechs{m}).(mechpar{p}));   %neuron: define values
                                            flag_strion_all(tt) = true;
                                        else
                                            str = sprintf('%s%s = %g\n',str,mechpar{p},neuron{n}.mech{t}.all.(mechs{m}).(mechpar{p}));   %neuron: define values
                                        end
                                    else
                                        str = sprintf('%s%s_%s = %g\n',str,mechpar{p},mechs{m},neuron{n}.mech{t}.all.(mechs{m}).(mechpar{p}));   %neuron: define values
                                    end
                                end
                            end
                        end
                        fprintf(ofile,sprintf('%s}\n\n',str));
                    end
                    
                    if isfield(tree{neuron{n}.tree(tt)},'R')
                        uR = unique(tree{neuron{n}.tree(tt)}.R); % Region indices that exist in tree
                        if ~isempty(intersect(tree{neuron{n}.tree(tt)}.rnames(uR),fields)) %isstruct(neuron{n}.mech{t}.(fields{1}))  %check if mechanism was defined dependent on existent region
                            regs = fields;  %if yes (some of) the input are the regions
                            regs = intersect(tree{neuron{n}.tree(tt)}.rnames(uR),regs);  % only use those region names which are existent in tree
                            strion_reg{tt} = cell(numel(regs),1);
                            flag_strion_reg{tt} = false(numel(regs),1);
                            strnseg_reg{tt} = cell(numel(regs),1);
                            flag_strnseg_reg{tt} = false(numel(regs),1);
                            for r = 1 : numel(regs)
                                str = sprintf('forsec cellList.o(%d).reg%s {\n',tt-1,regs{r});   %neuron:go through this region
                                strnseg_reg{tt}{r} = sprintf('forsec cellList.o(%d).reg%s {\n',tt-1,regs{r});   %neuron:go through this region
                                mechs = fieldnames(neuron{n}.mech{t}.(regs{r}));                % mechanism names are the fieldnames in the structure
                                if any(strcmp(mechs,'nseg'))
                                    mechs = setdiff(mechs,'nseg');
                                    strnseg_reg{tt}{r} = sprintf('%snseg = %d\n',strnseg_reg{tt}{r},neuron{n}.mech{t}.(regs{r}).nseg);   %neuron: define values
                                    flag_strnseg_reg{tt}(r) = true;
                                end
                                for m = 1:numel(mechs)      % loop through mechanisms
                                    str = sprintf('%sinsert %s\n',str,mechs{m});        % neuron:insert this mechanism
                                    
                                    if ~isempty(neuron{n}.mech{t}.(regs{r}).(mechs{m}))
                                        mechpar = fieldnames(neuron{n}.mech{t}.(regs{r}).(mechs{m}));
                                        for p = 1:numel(mechpar)  % loop through mechanism parameters
                                            if strcmpi(mechpar{p},'cm') || strcmpi(mechpar{p},'Ra') || (~isempty(strfind(mechs{m},'_ion')) &&  (numel(mechpar{p}) <= strfind(mechs{m},'_ion') || (numel(mechpar{p}) > strfind(mechs{m},'_ion') && ~strcmp(mechpar{p}(strfind(mechs{m},'_ion')+1),'0'))))       %if mechanism is an ion or passive cm/Ra, leave out mechansim suffix
                                                if ~isempty(strfind(mechs{m},'_ion')) && strcmpi(mechpar{p},'style')
                                                    if numel(neuron{n}.mech{t}.all.(mechs{m}).(mechpar{p})) ~= 5
                                                        for nn = 1:numel(neuron)
                                                            delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                                                        end
                                                        error('Error! Style specification of ion "%s" should be 5 numbers (see NEURON or t2n documentation)',mechs{m})
                                                    end
                                                    strion_reg{tt}{r} = sprintf('%sion_style("%s",%d,%d,%d,%d,%d)\n',strion_reg{tt}{r},mechs{m},neuron{n}.mech{t}.(regs{r}).(mechs{m}).(mechpar{p}));   %neuron: define values
                                                    flag_strion_reg{tt}(r) = true;
                                                else
                                                    str = sprintf('%s%s = %g\n',str,mechpar{p},neuron{n}.mech{t}.(regs{r}).(mechs{m}).(mechpar{p}));   %neuron: define values
                                                end
                                                
                                            else
                                                if numel(neuron{n}.mech{t}.(regs{r}).(mechs{m}).(mechpar{p})) == 1
                                                    str = sprintf('%s%s_%s = %g\n',str,mechpar{p},mechs{m},neuron{n}.mech{t}.(regs{r}).(mechs{m}).(mechpar{p}));   %neuron: define values
                                                else
                                                    for nn = 1:numel(neuron)
                                                        delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                                                    end
                                                    error('Parameter %s of mechanism %s in region %s has more than one value, please check.',mechpar{p},mechs{m},regs{r})
                                                end
                                            end
                                        end
                                    end
                                end
                                fprintf(ofile,sprintf('%s}\n\n',str));
                            end
                        end
                    end
                    if any(strcmpi(fields,'range'))
                        if ~isfield(tree{neuron{n}.tree(tt)},'artificial')
                            %                             str = '';
                            [~, ia] = unique(minterf{neuron{n}.tree(tt)}(:,[2,4]),'rows','stable');  % find real segments in neuron simulation
                            ia = ia(~isnan(minterf{neuron{n}.tree(tt)}(ia,4))); % remove start nodes of a segment (cause their value belongs to segment -1)
                            ia(numel(ia)+1) = size(minterf{neuron{n}.tree(tt)},1)+1;   % add one entry
                            
                            mechs = fieldnames(neuron{n}.mech{t}.range);
                            for m = 1:numel(mechs)
                                vars = fieldnames(neuron{n}.mech{t}.range.(mechs{m}));
                                %                                 allvals = zeros(3,0);
                                %                                 thesevars = '';
                                for r = 1:numel(vars)
                                    if numel(neuron{n}.mech{t}.range.(mechs{m}).(vars{r})) == numel(tree{neuron{n}.tree(tt)}.X)
                                        allvals = zeros(3,0);
                                        for in = 1:numel(ia)-1
                                            thisval = nanmean(neuron{n}.mech{t}.range.(mechs{m}).(vars{r})(minterf{neuron{n}.tree(tt)}(ia(in),1):minterf{neuron{n}.tree(tt)}(ia(in+1)-1,1))); % the value is the mean of all tree nodes which are simulated by this segment, if first node is start of section, ignore this one, since it belongs to old region
                                            
                                            if ~isnan(thisval)
                                                allvals = cat(2,allvals,[minterf{neuron{n}.tree(tt)}(ia(in),[2,4]),thisval]');
                                            end
                                        end
                                        
                                        %                                         thesevars = sprintf('%s"%s_%s",',thesevars,vars{r},mechs{m});
                                        secname = sprintf('range_%s_%s_%s_sec.dat',tree{neuron{n}.tree(tt)}.NID,vars{r},mechs{m});
                                        f = fopen(fullfile(exchfolder,thisfolder,secname) ,'Wt');
                                        fprintf(f,'%g\n',allvals(1,:));
                                        fclose(f);
                                        segname = sprintf('range_%s_%s_%s_seg.dat',tree{neuron{n}.tree(tt)}.NID,vars{r},mechs{m});
                                        f = fopen(fullfile(exchfolder,thisfolder,segname) ,'Wt');
                                        fprintf(f,'%g\n',allvals(2,:));
                                        fclose(f);
                                        valname = sprintf('range_%s_%s_%s_val.dat',tree{neuron{n}.tree(tt)}.NID,vars{r},mechs{m});
                                        f = fopen(fullfile(exchfolder,thisfolder,valname) ,'Wt');
                                        fprintf(f,'%g\n',allvals(3,:));
                                        fclose(f);
                                        if any(strcmp({'cm','Ra'},vars{r}))  % if variable is cm or Ra, do not write _"mech"  behind it
                                            rangestr = sprintf('%sset_range(%d,"%s","%s","%s","%s")\n',rangestr,tt-1,secname,segname,valname,vars{r});
                                        else
                                            rangestr = sprintf('%sset_range(%d,"%s","%s","%s","%s_%s")\n',rangestr,tt-1,secname,segname,valname,vars{r},mechs{m});
                                        end
                                    else
                                        for nn = 1:numel(neuron)
                                            delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                                        end
                                        error('Range variable definition should be a vector with same number of elements as tree has nodes')
                                        %                                         return
                                    end
                                end
                            end
                            
                        else
                            for nn = 1:numel(neuron)
                                delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                            end
                            error('Setting range variables for artificial cells is invalid')
                        end
                    end
                end
                if neuron{refPar}.params.parallel
                    fprintf(ofile,'}\n');
                end
            end
            fprintf(ofile,'\n\n');
            
            if any(cellfun(@any,flag_strion_reg)) || any(flag_strion_all)
                fprintf(ofile,'// ***** Now add specific ion styles *****\n');
                if any(flag_strion_all)
                    for tt = 1:numel(neuron{n}.tree)
                        if flag_strion_all(tt)
                            if neuron{refPar}.params.parallel
                                fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                            end
                            fprintf(ofile,sprintf('%s}\n\n',strion_all{tt}));
                            if neuron{refPar}.params.parallel
                                fprintf(ofile,'}\n');
                            end
                        end
                    end
                end
                if any(cellfun(@any,flag_strion_reg))
                    for tt = 1:numel(neuron{n}.tree)
                        if neuron{refPar}.params.parallel && any(flag_strnseg_reg{tt})
                            fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                        end
                        for r = 1:numel(flag_strion_reg{tt})
                            if flag_strion_reg{tt}(r)
                                fprintf(ofile,sprintf('%s}\n\n',strion_reg{tt}{r}));
                                
                            end
                        end
                        if neuron{refPar}.params.parallel && any(flag_strnseg_reg{tt})
                            fprintf(ofile,'}\n');
                        end
                    end
                end
            end
            
            fprintf(ofile,'// ***** Define nseg for all cells *****\n');
            fprintf(ofile, 'proc make_nseg() {\n');
            fprintf(ofile, 'for CELLINDEX = 0, cellList.count -1 {\n');
            if neuron{refPar}.params.parallel
                fprintf(ofile,'if (pc.gid_exists(CELLINDEX)) {\n');
            end
            fprintf(ofile, 'if (cellList.o(CELLINDEX).is_artificial == 0) {\n');
            if isfield(neuron{refPar}.params,'nseg') && isnumeric(neuron{refPar}.params.nseg)
                fprintf(ofile, 'forsec cellList.o(CELLINDEX).allreg {\n');
                fprintf(ofile, sprintf('nseg = %f\n}\n}\n',round(neuron{refPar}.params.nseg)) );
                if rem(round(neuron{refPar}.params.nseg),2) == 0
                    warning('nseg is not odd! Please reconsider nseg');
                end
            elseif isfield(neuron{refPar}.params,'nseg') && strcmpi(neuron{refPar}.params.nseg,'dlambda')
                fprintf(ofile, 'geom_nseg()\n}\n');
            elseif isfield(neuron{refPar}.params,'nseg') && ~isempty(strfind(neuron{refPar}.params.nseg,'ach'))
                each = cell2mat(textscan(neuron{refPar}.params.nseg,'%*s %d')); % get number
                fprintf(ofile, 'forsec cellList.o(CELLINDEX).allreg {\n');
                fprintf(ofile, sprintf('n = L/%d\nnseg = n+1\n}\n}\n',each) );
            else
                fprintf(ofile, '// No nseg specified!!!\n}\n');
                warning('nseg has not been specified in neuron.params.nseg (correctly?)!')
            end
            if neuron{refPar}.params.parallel
                fprintf(ofile,'}\n');
            end
            fprintf(ofile,'}\n\n');
            if any(cellfun(@any,flag_strnseg_reg)) || any(flag_strnseg_all)
                fprintf(ofile,'// ***** Add specific nseg definitions *****\n');
                if any(flag_strnseg_all)
                    for tt = 1:numel(neuron{n}.tree)
                        if neuron{refPar}.params.parallel
                            fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                        end
                        fprintf(ofile,sprintf('%s}\n\n',strnseg_all{tt}));
                        if neuron{refPar}.params.parallel
                            fprintf(ofile,'}\n');
                        end
                    end
                end
                if any(cellfun(@any,flag_strnseg_reg))
                    for tt = 1:numel(neuron{n}.tree)
                        if neuron{refPar}.params.parallel && any(flag_strnseg_reg{tt})
                            fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                        end
                        for r = 1:numel(flag_strnseg_reg{tt})
                            if flag_strnseg_reg{tt}(r)
                                fprintf(ofile,sprintf('%s}\n\n',strnseg_reg{tt}{r}));
                            end
                        end
                        if neuron{refPar}.params.parallel && any(flag_strnseg_reg{tt})
                            fprintf(ofile,'}\n');
                        end
                    end
                end
            end
            fprintf(ofile,'}\n\n');
            
            
            fprintf(ofile,'// ***** Now adjust number of segments *****\n');
            fprintf(ofile,'make_nseg()\n');
            if ~isempty(rangestr)
                fprintf(ofile,'\n\n');
                fprintf(ofile,'// ***** Set specified range variables *****\n');
                fprintf(ofile,rangestr);
                fprintf(ofile,'\n\n');
            end
        end
        fclose(ofile);          %close file
    elseif exist(fullfile(exchfolder,thisfolder,'init_mech.hoc'),'file')
        delete(fullfile(exchfolder,thisfolder,'init_mech.hoc'));
    end
    
    %% write init_pp.hoc
    
    if t2n_getref(n,neuron,'pp') == n     %rewrite only if PP def is not taken from previous sim
        ofile = fopen(fullfile(exchfolder,thisfolder,'init_pp.hoc') ,'wt');   %open morph hoc file in write modus
        fprintf(ofile,'\n\n');
        fprintf(ofile,'// ***** Place synapses, electrodes or other point processes *****\n');
        if isfield(neuron{n},'pp')
            count = 0;
            for tt = 1:numel(neuron{n}.tree)
                t = neuron{n}.tree(tt);
                if numel(neuron{n}.pp) >= t && ~isempty(neuron{n}.pp{t})   && ~isfield(tree{neuron{n}.tree(tt)},'artificial')    % if point processes are defined for this tree
                    if neuron{refPar}.params.parallel
                        fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                    end
                    ppfield = fieldnames(neuron{n}.pp{t});
                    for f1 = 1:numel(ppfield)
                        %%%%
                        for n1 = 1:numel(neuron{n}.pp{t}.(ppfield{f1}))
                            node = neuron{n}.pp{t}.(ppfield{f1})(n1).node;
                            for in = 1:numel(node)
                                inode = find(minterf{neuron{n}.tree(tt)}(:,1) == node(in),1,'first');    %find the index of the node in minterf
                                fprintf(ofile,sprintf('cellList.o(%d).allregobj.o(%d).sec',tt-1,minterf{neuron{n}.tree(tt)}(inode,2) ) );    % corresponding section of node
                                fprintf(ofile,sprintf('{pp = new %s(%f)\n',ppfield{f1},minterf{neuron{n}.tree(tt)}(inode,3) ) );  % new pp
                                fields = setdiff(fieldnames(neuron{n}.pp{t}.(ppfield{f1})(n1)),{'node','id'});
                                
                                if any(strcmp(ppfield{f1},{'IClamp','SEClamp','SEClamp2','VClamp'})) && (any(strcmp(fields,'times')) || (any(strcmp(fields,'dur')) && (numel(neuron{n}.pp{t}.(ppfield{f1})(n1).dur) > 3 || (isfield(neuron{n}.pp{t}.(ppfield{f1})(n1),'del') && neuron{n}.pp{t}.(ppfield{f1})(n1).del == 0))))  % check if field "times" exists or multiple durations are given or del is zero (last point can introduce a bug when cvode is active)
                                    if any(strcmp(fields,'times'))
                                        times = sprintf('%f,',neuron{n}.pp{t}.(ppfield{f1})(n1).times);
                                    else   %bugfix since seclamp can only use up to 3 duration specifications
                                        times = sprintf('%f,',[0 cumsum(neuron{n}.pp{t}.(ppfield{f1})(n1).dur(1:end-1))]);
                                    end
                                    amps = sprintf('%f,',neuron{n}.pp{t}.(ppfield{f1})(n1).amp);
                                    times = times(1:end-1); amps = amps(1:end-1); % delete last commas
                                    
                                    fprintf(ofile,'playt = new Vector()\n');
                                    fprintf(ofile,sprintf('playt = playt.append(%s)\n',times));
                                    fprintf(ofile,'play = new Vector()\n');
                                    fprintf(ofile,sprintf('play = play.append(%s)\n',amps));
                                    
                                    switch ppfield{f1}
                                        case 'IClamp'    % if SEClamp and VClamp dur and amp would be handled equally this could be simplified much more =/
                                            fprintf(ofile,'play.play(&pp.amp,playt)\n');
                                            fprintf(ofile,'pp.dur = 1e15\n');
                                            fprintf(ofile,'pp.del = -1e4\n');
                                        case 'VClamp'
                                            fprintf(ofile,'play.play(&pp.amp[0],playt)\n');
                                            fprintf(ofile,'pp.dur[0] = 1e15\n');
                                        case {'SEClamp','SEClamp2'}
                                            fprintf(ofile,'play.play(&pp.amp1,playt)\n');
                                            fprintf(ofile,'pp.dur1 = 1e15\n');
                                    end
                                    fields = setdiff(fields,{'times','amp','dur','del'});
                                    fprintf(ofile,'io = playtList.append(playt)\n');
                                    fprintf(ofile,'io = playList.append(play)\n');
                                    fprintf(ofile, 'objref play\n');
                                    fprintf(ofile, 'objref playt\n');
                                end
                                
                                for f2 =1:numel(fields)  % go through all parameter fields and declare them
                                    if any(strcmpi(fields{f2},{'dur','amp'})) && any(strcmp(ppfield{f1},{'SEClamp2','SEClamp','VClamp'}))   % for dur and amp, there are multiple values
                                        for ff = 1:numel(neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2}))
                                            switch ppfield{f1}
                                                case 'VClamp'
                                                    fprintf(ofile,sprintf('pp.%s[%d] = %f \n',fields{f2},ff-1,neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2})(ff)));
                                                case {'SEClamp','SEClamp2'}
                                                    fprintf(ofile,sprintf('pp.%s%d = %f \n',fields{f2},ff,neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2})(ff)) );
                                            end
                                        end
                                        
                                    else
                                        if numel(neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2})) > 1
                                            if numel(neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2})) == numel(node)
                                                if iscell(neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2})(in)) && ischar(neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2}){in}) && regexpi(neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2}){in},'^(.*)$')  % check if this is a class/value pair, then use the () instead of =
                                                    fprintf(ofile,sprintf('pp.%s%s \n', fields{f2},neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2}){in} ));
                                                else
                                                    fprintf(ofile,sprintf('pp.%s = %f \n', fields{f2},neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2})(in)) );
                                                end
                                            else
                                                for nn = 1:numel(neuron)
                                                    delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                                                end
                                                error('Caution: "%s" vector of PP "%s" has wrong size!\n It has to be equal 1 or equal the number of nodes where the PP is inserted,',fields{f2},ppfield{f1})
                                            end
                                        else
                                            if ischar(neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2})) && regexpi(neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2}),'^(.*)$')  % check if this is a class/value pair, then use the () instead of =
                                                fprintf(ofile,sprintf('pp.%s%s \n', fields{f2},neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2}) ));
                                            else
                                                fprintf(ofile,sprintf('pp.%s = %f \n', fields{f2},neuron{n}.pp{t}.(ppfield{f1})(n1).(fields{f2})) );
                                            end
                                        end
                                    end
                                end
                                
                                fprintf(ofile,'}\n');
                                fprintf(ofile,'io = ppList.append(pp)\n' );  %append pp to ppList
                                neuron{n}.pp{t}.(ppfield{f1})(n1).id(in) = count;   % save id to pplist in Neuron (for find the correct object for recording later)
                                count = count +1; %ppnum(t) = ppnum(t) +1;  % counter up
                            end
                        end
                    end
                    if neuron{refPar}.params.parallel
                        fprintf(ofile,'}\n');
                    end
                end
            end
            fprintf(ofile, 'objref pp\n');
        end
        fclose(ofile);
    end
    
    
    %% write init_con.hoc
    
    if neuron{refPar}.params.parallel || t2n_getref(n,neuron,'con') == n     %rewrite only if connections are not taken from previous sim
        ofile = fopen(fullfile(exchfolder,thisfolder,'init_con.hoc') ,'wt');   %open morph hoc file in write modus
        if neuron{refPar}.params.parallel
            for g = 1:numel(GIDs)
                thiscell = GIDs(g).cell;
                if isfield(tree{thiscell},'artificial')
                    fprintf(ofile,'con = new NetCon(cell,nil)\n');     % make temporary netcon for registering the cell
                else
                    inode = find(minterf{thiscell}(:,1) == GIDs(g).node,1,'first');
                    fprintf(ofile,'cell.allregobj.o(%d).sec {con = new NetCon(&%s(0.5),nil)}\n',minterf{neuron{n}.tree(tt)}(inode,2),GIDs(g).watch);  % make temporary netcon for registering the cell
                end
                fprintf(ofile,'pc.cell(%d,con)\nobjref con\n',tt-1);  % register cell at this worker
            end
        end
        fprintf(ofile,'\n\n');
        fprintf(ofile,'// ***** Define Connections *****\n');
        if isfield(neuron{n},'con')
            if neuron{refPar}.params.parallel
                fprintf(ofile,'pc.barrier()\n'); % wait for all workers
            end
            for c = 1:numel(neuron{n}.con)
                str = cell(0);
                nodeflag = false;
                sourcefields = setdiff(fieldnames(neuron{n}.con(c).source),{'cell','watch'});
                
                cell_source = neuron{n}.con(c).source.cell;
                if isempty(sourcefields)   % probably an artificial cell...in that case "cell_source" can be a multi array, create a NetCon for each of these sources
                    for t = 1:numel(cell_source)
                        if ~isempty(cell_source(t))
                            if isfield(tree{cell_source(t)},'artificial')
                                if neuron{refPar}.params.parallel
                                    str{t} = sprintf('con = pc.gid_connect(%d,',find(neuron{n}.tree==cell_source(t))-1);
                                else
                                    str{t} = sprintf('con = new NetCon(cellList.o(%d).cell,',find(neuron{n}.tree==cell_source(t))-1);
                                end
                            else
                                error('In con(%d) it seems you specified a connection from a real cell (%d) without specifying a node location! Please specify under con(%d).source.node',c,t,c)
                            end
                        else
                            str{t} = sprintf('con = new NetCon(nil,');
                        end
                    end
                else
                    if numel(cell_source) > 1
                        for nn = 1:numel(neuron)
                            delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                        end
                        error('Error in connection %d of neuron instance %d! You must define a single cell ID if the source of a NetCon is a PointProcess or a section!',c,n)
                    end
                    if any(strcmp(sourcefields,'pp'))  % point process is the source
                        pp = neuron{n}.con(c).source.pp;
                        %                         [~,iid] = intersect(neuron{refPP}.pp{cell_source}.(pp).node,neuron{n}.con(c).source.node); % get reference to the node location of the PPs that should be connected
                        % that is not working if several pp are defined at
                        % that node. here comes the workaround
                        if isfield(neuron{n}.con(c).source,'ppg')  % check for an index to a PP subgroup
                            ppg = neuron{n}.con(c).source.ppg;
                        else
                            ppg = 1:numel(neuron{refPP}.pp{cell_source}.(pp));  % else take all PP subgroups
                        end
                        
                        upp = unique(cat(1,neuron{refPP}.pp{cell_source}.(pp)(ppg).node));  % unique pp nodes of the cell
                        if numel(upp) == 1 % otherwise hist would make as many bins as upp
                            cpp = numel(cat(1,neuron{refPP}.pp{cell_source}.(pp)(ppg).node));%1;
                        else
                            cpp =hist(cat(1,neuron{refPP}.pp{cell_source}.(pp)(ppg).node),upp); % number of pps at the same nodes
                        end
                        ucon = unique(neuron{n}.con(c).source.node); % unique connection nodes declared to the cell
                        if numel(ucon) == 1  % otherwise hist would make as many bins as ucon
                            ccon = numel(neuron{n}.con(c).source.node);
                        else
                            ccon =hist(neuron{n}.con(c).source.node,ucon); % number of connections to the same node
                        end
                        iid = cell(numel(neuron{n}.pp{cell_source}.(pp)(ppg)),1);  % initialize ids to pps %!%!%!%!
                        for uc = 1:numel(ucon)  % go trough all nodes that should be connected from
                            if any(ucon(uc) == upp)  % check if the pp exists there
                                for n1 = 1:numel(iid)
                                    ind = find(neuron{refPP}.pp{cell_source}.(pp)(ppg(n1)).node == ucon(uc));  % find all PPs at that node
                                    if ~isempty(ind)
                                        if cpp(ucon(uc) == upp) == ccon(uc)    % same number of PPs and connections, put them together, should be ok without warning
                                            iid{n1} = cat (1,iid{n1},ind);
                                        else
                                            for nn = 1:numel(neuron)
                                                delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                                            end
                                            error('Error cell %d. %d connections are declared to start from from %d %ss at node %d. Making a connection from PP at a node where multiple of these PPs exist is not allowed. Probably you messed something up',cell_source,ccon(uc),cpp(ucon(uc) == upp),pp,ucon(uc)) % give an error if more connections were declared than PPs exist at that node
                                        end
                                    end
                                end
                                
                            else
                                fprintf('Warning cell %d. PP %s for connection does not exist at node %d',neuron{n}.con(c).target.cell,pp,ucon(uc))
                            end
                        end
                        
                        for ii = 1:numel(iid)
                            if neuron{refPar}.params.parallel
                                str{ii} = sprintf('con = new NetCon(ppList.o(%d),nil)\npc.cell(%d,con)\nobjref con\n',neuron{refPP}.pp{cell_source}.(pp).id(iid{ii}),neuron{n}.con(c).source.gid(ii));
                                % connect gid with pp object
                            else
                                str{ii} = sprintf('con = new NetCon(ppList.o(%d),',neuron{refPP}.pp{cell_source}.(pp).id(iid{ii}));
                            end
                        end
                    else   % a normal section is the source
                        node = neuron{n}.con(c).source.node;
                        for in = 1:numel(node)
                            inode = find(minterf{cell_source}(:,1) == node(in),1,'first');    %find the index of the node in minterf
                            if isfield(neuron{n}.con(c).source,'watch') && ischar(neuron{n}.con(c).source.watch) && ~strcmp(neuron{n}.con(c).source.watch,'v')
                                if neuron{refPar}.params.parallel
                                    error('T2N does not (yet) implement watching anything different than voltage in netcons that span workers')
                                else
                                    str{in} = sprintf('cellList.o(%d).allregobj.o(%d).sec {con = new NetCon(&%s(%f),',find(neuron{n}.tree==cell_source)-1,minterf{neuron{n}.tree(cell_source)}(inode,2),neuron{n}.con(c).source.watch,minterf{neuron{n}.tree==cell_source}(inode,3));
                                end
                            else
                                if neuron{refPar}.params.parallel
                                    %!%!%! look here which node and use the
                                    %GIDs.gid .......
                                    %pc.gid_connect(srcgid,targetobj)
                                    str{in} = sprintf('cellList.o(%d).allregobj.o(%d).sec {con = new NetCon(&v(%f),',find(neuron{n}.tree==cell_source)-1,minterf{neuron{n}.tree(cell_source)}(inode,2),minterf{neuron{n}.tree==cell_source}(inode,3));
                                else
                                    str{in} = sprintf('cellList.o(%d).allregobj.o(%d).sec {con = new NetCon(&v(%f),',find(neuron{n}.tree==cell_source)-1,minterf{neuron{n}.tree(cell_source)}(inode,2),minterf{neuron{n}.tree==cell_source}(inode,3));
                                end
                            end
                        end
                        nodeflag = true;
                    end
                    
                end
                
                %%%
                
                targetfields = setdiff(fieldnames(neuron{n}.con(c).target),'cell');
                newstr = cell(0);
                count = 1;
                for it = 1:numel(neuron{n}.con(c).target)
                    cell_target = neuron{n}.con(c).target(it).cell;
                    if isempty(targetfields)   % probably an artificial cell...
                        for t1 = 1:numel(cell_source)
                            for t2 = 1:numel(cell_target)
                                if ~isempty(cell_target(t2)) && isfield(tree{cell_target(t2)},'artificial')
                                    newstr{count} = sprintf('%scellList.o(%d).cell',str{t1},find(neuron{n}.tree==cell_target(t2))-1);
                                else
                                    newstr{count} = sprintf('%snil',str{t1});
                                end
                                count = count +1;
                            end
                        end
                    elseif any(strcmp(targetfields,'pp'))  % point process is the target
                        pp = neuron{n}.con(c).target(it).pp;
                        %                         %                         neuron{refPP}.pp{t_target}.(pp).node
                        %                         [~,iid] = intersect(neuron{refPP}.pp{cell_target}.(pp).node,neuron{n}.con(c).target(it).node); % get reference to the node location of the PPs that should be connected
                        %                         intersect unfortunately fails if more than one PP
                        %                         is declared at the same node and con wants to
                        %                         target both. here comes the workaround
                        if isfield(neuron{n}.con(c).target(it),'ppg')
                            ppg = neuron{n}.con(c).target(it).ppg;
                        else
                            ppg = 1:numel(neuron{refPP}.pp{cell_target}.(pp));
                        end
                        upp = unique(cat(1,neuron{refPP}.pp{cell_target}.(pp)(ppg).node));  % unique pp nodes of the cell
                        if numel(upp) == 1 % otherwise hist would make as many bins as upp
                            cpp = numel(cat(1,neuron{refPP}.pp{cell_target}.(pp)(ppg).node));%1;
                        else
                            cpp =hist(cat(1,neuron{refPP}.pp{cell_target}.(pp)(ppg).node),upp); % number of pps at the same nodes
                        end
                        ucon = unique(neuron{n}.con(c).target(it).node); % unique connection nodes declared to the cell
                        if numel(ucon) == 1  % otherwise hist would make as many bins as ucon
                            ccon = numel(neuron{n}.con(c).target(it).node);
                        else
                            ccon =hist(neuron{n}.con(c).target(it).node,ucon); % number of connections to the same node
                        end
                        iid = cell(numel(neuron{n}.pp{cell_target}.(pp)(ppg)),1);  % initialize ids to pps
                        for uc = 1:numel(ucon)  % go trough all nodes that should be connected to
                            if any(ucon(uc) == upp)  % check if the pp exists there
                                %
                                for n1 = 1:numel(iid)
                                    ind = find(neuron{refPP}.pp{cell_target}.(pp)(ppg(n1)).node == ucon(uc));  % find all PPs at that node
                                    if ~isempty(ind)
                                        if cpp(ucon(uc) == upp) < ccon(uc)  % less PPs exist than connections to node
                                            if numel(ind) == 1
                                                iid{n1} = cat (1,iid{n1},repmat(ind,ccon(uc),1));  % add as many PPs from that node to the id list as connections were declared (or as pps exist there)
                                                fprintf('Warning cell %d. More connections to same %s declared than %ss at that node. All connections target now that %s.',cell_target,pp,pp,pp) % give a warning if more connections were declared than PPs exist at that node
                                            else
                                                for nn = 1:numel(neuron)
                                                    delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                                                end
                                                error('Error cell %d. %d connections are declared to %d %ss at node %d. Probably you messed something up',cell_target,ccon(uc),cpp(ucon(uc) == upp),pp,ucon(uc)) % give an error if more connections were declared than PPs exist at that node
                                            end
                                        elseif cpp(ucon(uc) == upp) > ccon(uc)  % more PPs exist than connections to node
                                            if isfield(neuron{n}.con(c).target(it),'ipp')
                                                iid{n1} = cat (1,iid{n1},ind(neuron{n}.con(c).target(it).ipp));
                                            else
                                                iid{n1} = cat (1,iid{n1},ind(1:min(cpp(ucon(uc) == upp),ccon(uc))));  % add as many PPs from that node to the id list as connections were declared (or as pps exist there)
                                                fprintf('Warning cell %d, node %d. Less connections to same %s declared than %ss at that node. Connections target now only the first %d %ss.',cell_target,ucon(uc),pp,pp,min(cpp(ucon(uc) == upp),ccon(uc)),pp) % give a warning if more connections were declared than PPs exist at that node
                                            end
                                        else   % same number of PPs and connections, put them together, should be ok without warning
                                            iid{n1} = cat (1,iid{n1},ind);
                                        end
                                        
                                    end
                                end
                                
                            else
                                fprintf('Warning cell %d. PP %s for connection does not exist at node %d',cell_target,pp,ucon(uc))
                            end
                        end
                        if numel(unique(cat(1,iid{:}))) ~= numel(cat(1,iid{:}))
                            fprintf('Warning cell %d. Connection #%d targets the PP %s at one or more nodes where several %s groups are defined! Connection is established to all of them. Use "neuron.con(refPP).target(y).ppg = z" to connect only to the zth group of PP %s.',neuron{n}.con(c).target.cell,c,pp,pp,pp)
                        end
                        for t1 = 1:numel(cell_source)
                            for n1 = 1:numel(iid)
                                for ii = 1:numel(iid{n1})
                                    newstr{count} = sprintf('%sppList.o(%d)',str{t1},neuron{refPP}.pp{cell_target}.(pp)(ppg(n1)).id(iid{n1}(ii)));
                                    count = count +1;
                                end
                            end
                        end
                        
                    else
                        warning('No target specified as connection')
                        for t1 = 1:numel(cell_source)
                            newstr{count} = sprintf('%snil',str{t1});
                            count = count + 1;
                        end
                    end
                end
                for s = 1:numel(newstr)
                    if isfield(neuron{n}.con(c),'threshold')
                        newstr{s} = sprintf('%s,%g', newstr{s},neuron{n}.con(c).threshold);
                    else
                        newstr{s} = sprintf('%s,10', newstr{s});
                    end
                    if isfield(neuron{n}.con(c),'delay')
                        newstr{s} = sprintf('%s,%g', newstr{s},neuron{n}.con(c).delay);
                    else
                        newstr{s} = sprintf('%s,1', newstr{s});
                    end
                    if isfield(neuron{n}.con(c),'weight')
                        newstr{s} = sprintf('%s,%g)\n', newstr{s},neuron{n}.con(c).weight);
                    else
                        newstr{s} = sprintf('%s,0)\n', newstr{s});
                        disp('Caution: NetCon Weight initialized with default (0) !')
                    end
                    newstr{s} = sprintf('%sio = conList.append(con)',newstr{s});  %append con to conList
                    if nodeflag
                        newstr{s} = sprintf('%s}\n',newstr{s});
                    else
                        newstr{s} = sprintf('%s\n',newstr{s});
                    end
                end
                fprintf(ofile,strjoin(newstr));  % new connection
            end
            fprintf(ofile, 'objref con\n');
        end
        fprintf(ofile,'\n\n');
        fclose(ofile);
    elseif exist(fullfile(exchfolder,thisfolder,'init_con.hoc'),'file')
        delete(fullfile(exchfolder,thisfolder,'init_con.hoc'));
    end
    
    
    %% write init_rec.hoc
    if (~isnan(refR) || ~isnan(refAP)) && (refR==n || refAP==n || refAP~=refR)     %rewrite only if one or both of record/APCount are not taken from previous sim or if both are taken from another sim but from different ones (not possible because both are in one hoc)
        ofile = fopen(fullfile(exchfolder,thisfolder,'init_rec.hoc') ,'wt');   %open record hoc file in write modus
        fprintf(ofile,'\n\n');
        fprintf(ofile,'// ***** Define recording sites *****\n');
        if ~isnan(refR)
            count = 0;  % counter for recording vector List
            countt = -1; % counter for time vector List
            for tt = 1:numel(neuron{n}.tree)
                t = neuron{n}.tree(tt);
                if numel(neuron{refR}.record) >= t && ~isempty(neuron{refR}.record{t})  % if a recording site was defined for  this tree
                    if neuron{refPar}.params.parallel
                        fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                    end
                    if neuron{refPar}.params.use_local_dt
                        makenewrect = true;
                    end
                    recfields = fieldnames(neuron{refR}.record{t});
                    if isfield(tree{neuron{n}.tree(tt)},'artificial')
                        if numel(recfields) > 1 && strcmp(recfields,'record')
                            neuron{refR}.record{t} = struct(tree{neuron{n}.tree(tt)}.artificial,neuron{refR}.record{t}); % put the structure in field named as the artificial neuron
                        end
                    end
                    recfields = fieldnames(neuron{refR}.record{t});
                    
                    for f1 = 1:numel(recfields)
                        if isfield(tree{neuron{n}.tree(tt)},'artificial')
                            rectype = 'artificial';
                        elseif strcmp(recfields{f1},'cell')      % check if recording should be a parameter in a section, or a point process (divided in pps and electrodes)
                            rectype = 'cell';
                        else
                            rectype = 'pp';
                        end
                        % these lines filter out multiple
                        % recording node definitions
                        if n == refR  % only do it once for each real defined simulation
                            if numel(setdiff(fieldnames(neuron{refR}.record{t}.(recfields{f1})),{'record','node'}))>0
                                error('this has not been implemented yet. write to marcel.beining@gmail.com with specification of the error line')
                            end
                            [uniqrecs,~,indrecgroups] = unique({neuron{refR}.record{t}.(recfields{f1}).record}); % find recording fields with same recording variable
                            if strcmp(recfields{f1},'cell') || numel(neuron{refPP}.pp{t}.(recfields{f1})) == 1  % leave this out if several groups of pps are defined
                                tmpstruct = neuron{refR}.record{t}.(recfields{f1})([]);
                                for u = 1:numel(uniqrecs)  % go through variable groups
                                    unodes = unique(cat(1,neuron{refR}.record{t}.(recfields{f1})(indrecgroups==u).node));  % get the unique nodes for that recorded variable
                                    tmpstruct(u) = struct('record',uniqrecs{u},'node',unodes);  % save these in a temporary structure
                                end
                                neuron{refR}.record{t}.(recfields{f1}) = tmpstruct;  % overwrite old record defiition with new record structure
                            else
                                warning('It seems recordings of different PP groups have been defined. Make sure that indices match, e.g. .record{1}.ExpSyn(3) is to target only .pp{1}.ExpSyn(3) etc.\n')
                            end
                        end
                        for r = 1:numel(neuron{refR}.record{t}.(recfields{f1})) %.record)  % go through all variables to be recorded
                            
                            if strcmp(rectype,'cell')
                                if isfield(tree{neuron{n}.tree(tt)},'R') && isfield(tree{neuron{n}.tree(tt)},'rnames')
                                    Rs = tree{neuron{n}.tree(tt)}.rnames(tree{neuron{n}.tree(tt)}.R(neuron{refR}.record{t}.cell(r).node));       % all region names of trees nodes
                                    strs = regexp(neuron{refR}.record{t}.cell(r).record,'_','split');            % split record string to get mechanism name
                                    if numel(strs)>1   %any(strcmp(strs{1},{'v','i'}))             % check if record variable is variable of a mechanism or maybe global
                                        ignorethese = false(1,numel(neuron{refR}.record{t}.cell(r).node));
                                        uRs = unique(Rs);
                                        str = '';
                                        for u = 1:numel(uRs)                                            % go through regions to be recorded
                                            if (~isfield(neuron{refM}.mech{t},uRs{u}) || isfield(neuron{refM}.mech{t},uRs{u}) && ~isfield(neuron{refM}.mech{t}.(uRs{u}),strs{end})) &&  (~isfield(neuron{refM}.mech{t},'all') || isfield(neuron{refM}.mech{t},'all') && ~isfield(neuron{refM}.mech{t}.all,strs{end}))             % check if this region also has the mechanism to be recorded
                                                ignorethese = ignorethese | strcmp(uRs{u},Rs);           % if not ignore these region for recording
                                                str = strcat(str,uRs{u},'/');
                                            end
                                        end
                                        if ~isempty(str)
                                            neuron{refR}.record{t}.cell(r).node(ignorethese) = [];                     % delete the recording nodes which should be ignored
                                            warning('Region(s) "%s" of tree %d do not contain mechanism "%s" for recording. Recording in this region is ignored',str(1:end-1),t,strs{end})
                                        end
                                    end
                                end
                            end
                            
                            if ~any(strcmp(rectype,'artificial'))
                                inode = zeros(numel(neuron{refR}.record{t}.(recfields{f1})(r).node),1);
                                for in = 1:numel(neuron{refR}.record{t}.(recfields{f1})(r).node)
                                    inode(in) = find(minterf{neuron{n}.tree(tt)}(:,1) == neuron{refR}.record{t}.(recfields{f1})(r).node(in),1,'first');    %find the index of the node in minterf
                                end
                                [realrecs,~,ic] = unique(minterf{neuron{n}.tree(tt)}(inode,[2,4]),'rows');
                                % put warning here !
                            end
                            
                            switch rectype
                                case 'cell'
                                    for in = 1:size(realrecs,1)
                                        fprintf(ofile,sprintf('rec = new Vector(%f)\n',(neuron{refPar}.params.tstop-neuron{refPar}.params.tstart)/neuron{refPar}.params.dt+1 ) );    % create new recording vector
                                        fprintf(ofile,sprintf('rec.label("%s at location %06.4f of section %d of cell %d")\n', neuron{refR}.record{t}.cell(r).record , realrecs(in,2), realrecs(in,1) ,tt-1) ); % label the vector for plotting
                                        if neuron{refPar}.params.cvode
                                            if makenewrect  % only make a new time vector for recording if a new simulation instance or a new cell (in case of use_local_dt)
                                                fprintf(ofile,sprintf('rect = new Vector(%f)\n',(neuron{refPar}.params.tstop-neuron{refPar}.params.tstart)/neuron{refPar}.params.dt+1 ) );    % create new recording vector
                                            end
                                            fprintf(ofile,sprintf('cellList.o(%d).allregobj.o(%d).sec {io = cvode.record(&%s(%f),rec,rect)}\n',tt-1,realrecs(in,1), neuron{refR}.record{t}.cell(r).record, realrecs(in,2) ) ); % record the parameter x at site y as specified in neuron{refR}.record
                                        else
                                            fprintf(ofile,sprintf('io = rec.record(&cellList.o(%d).allregobj.o(%d).sec.%s(%f),tvec)\n',tt-1,realrecs(in,1), neuron{refR}.record{t}.cell(r).record, realrecs(in,2) ) ); % record the parameter x at site y as specified in neuron{refR}.record
                                        end
                                        
                                        fprintf(ofile,'io = recList.append(rec)\n\n' );  %append recording vector to recList
                                        if neuron{refPar}.params.cvode
                                            if makenewrect
                                                fprintf(ofile,'io = rectList.append(rect)\n\n' );  %append time recording vector to recList
                                                countt = countt +1;
                                                makenewrect = false;
                                            end
                                            neuron{refR}.record{t}.cell(r).idt(in) = countt;   % reference to find recording in recList
                                        end
                                        neuron{refR}.record{t}.cell(r).id(in) = count;  % reference to find recording in recList
                                        count = count +1;
                                    end
                                    neuron{refR}.record{t}.cell(r).rrecs = realrecs; % gives the section and segment to the recordings
                                    neuron{refR}.record{t}.cell(r).irrecs = ic; % gives the the index to realrecs for each node
                                case 'pp'
                                    delin = [];
                                    %                                 [~,iid] = intersect(neuron{x3}.pp{t}.(recfields{f1}).node,neuron{refR}.record{t}.(recfields{f1}).node); % get reference to the node location of the PPs that should be connected
                                    if isfield(neuron{refR}.record{t}.(recfields{f1})(r),'ppg')
                                        ppg = neuron{refR}.record{t}.(recfields{f1})(r).ppg;
                                    elseif numel(neuron{refPP}.pp{t}.(recfields{f1})) == numel(neuron{refR}.record{t}.(recfields{f1}))
                                        ppg = r;
                                    else
                                        ppg =1;
                                    end
                                    for in =  1:size(realrecs,1)
                                        ind = find(neuron{refPP}.pp{t}.(recfields{f1})(ppg).node == neuron{refR}.record{t}.(recfields{f1})(r).node(in));
                                        if ~isempty(ind)
                                            fprintf(ofile,sprintf('rec = new Vector(%f)\n',(neuron{refPar}.params.tstop-neuron{refPar}.params.tstart)/neuron{refPar}.params.dt+1 ) );    % create new recording vector
                                            fprintf(ofile,sprintf('rec.label("%s of %s Point Process at location %06.4f of section %d of cell %d")\n', neuron{refR}.record{t}.(recfields{f1})(r).record , recfields{f1} , fliplr(realrecs(in,:)) ,tt-1) ); % label the vector for plotting
                                            if neuron{refPar}.params.cvode
                                                if makenewrect  % only make a new time vector for recording if a new simulation instance or a new cell (in case of use_local_dt)
                                                    fprintf(ofile,sprintf('rect = new Vector(%f)\n',(neuron{refPar}.params.tstop-neuron{refPar}.params.tstart)/neuron{refPar}.params.dt+1 ) );    % create new recording vector
                                                end
                                                fprintf(ofile,sprintf('cellList.o(%d).allregobj.o(%d).sec {io = cvode.record(&ppList.o(%d).%s,rec,rect)}\n',tt-1, realrecs(in,1),neuron{refPP}.pp{t}.(recfields{f1})(ppg).id(ind), neuron{refR}.record{t}.(recfields{f1})(r).record ) ); % record the parameter x at site y as specified in neuron{refR}.record
                                            else
                                                fprintf(ofile,sprintf('io = rec.record(&ppList.o(%d).%s,tvec)\n',neuron{refPP}.pp{t}.(recfields{f1})(ppg).id(ind), neuron{refR}.record{t}.(recfields{f1})(r).record ) ); % record the parameter x at site y as specified in neuron{refR}.record
                                            end
                                            fprintf(ofile,'io = recList.append(rec)\n\n' );  %append recording vector to recList
                                            if neuron{refPar}.params.cvode
                                                if makenewrect
                                                    fprintf(ofile,'io = rectList.append(rect)\n\n' );  %append time recording vector to recList
                                                    countt = countt +1;
                                                    makenewrect = false;
                                                end
                                                neuron{refR}.record{t}.(recfields{f1})(r).idt(in) = countt;    % reference to find recording in recList
                                            end
                                            
                                            neuron{refR}.record{t}.(recfields{f1})(r).id(in) = count;   % reference to find recording in recList
                                            count = count +1;
                                        else
                                            delin = cat(1,delin,in);
                                            neuron{refR}.record{t}.(recfields{f1})(r).id(in) = NaN;
                                            fprintf('Node %d of cell %d does not comprise the PP "%s". Recording is ignored.',neuron{refR}.record{t}.(recfields{f1})(r).node(in),t,recfields{f1})
                                            ic(ic == in) = [];  % if node does not correspond to some specified pp at that place, delete it
                                            ic(ic >= in) = ic(ic >= in) - 1;
                                        end
                                    end
                                    if ~isempty(delin)
                                        realrecs(delin,:) = [];  % if node does not correspond to some specified pp at that place, delete it
                                    end
                                    neuron{refR}.record{t}.(recfields{f1})(r).rrecs = realrecs;
                                    neuron{refR}.record{t}.(recfields{f1})(r).irrecs = ic; % gives the the index to realrecs for each node
                                case 'artificial'
                                    fprintf(ofile,sprintf('rec = new Vector(%f)\n',(neuron{refPar}.params.tstop-neuron{refPar}.params.tstart)/neuron{refPar}.params.dt+1 ) );    % create new recording vector
                                    fprintf(ofile,sprintf('rec.label("%s of artificial cell %s (cell #%d)")\n', neuron{refR}.record{t}.cell(r).record , tree{neuron{n}.tree(tt)}.artificial, tt-1) ); % label the vector for plotting
                                    if strcmpi(neuron{refR}.record{t}.cell(r).record,'on')
                                        fprintf(ofile,sprintf('nilcon = new NetCon(cellList.o(%d).cell,nil,%g,0,5)\n',tt-1,0.5) );    % for art. cells, make netcon with threshold 0.5
                                        fprintf(ofile,sprintf('io = nilcon.record(rec)\n'));
                                        fprintf(ofile,'io = nilconList.append(nilcon)\n\n' );  %append recording vector to recList
                                    else
                                        if neuron{refPar}.params.cvode
                                            if makenewrect  % only make a new time vector for recording if a new simulation instance or a new cell (in case of use_local_dt)
                                                fprintf(ofile,sprintf('rect = new Vector(%f)\n',(neuron{refPar}.params.tstop-neuron{refPar}.params.tstart)/neuron{refPar}.params.dt+1 ) );    % create new recording vector
                                            end
                                            fprintf(ofile,sprintf('io = cvode.record(&cellList.o(%d).cell.%s,rec,rect)\n',tt-1, neuron{refR}.record{t}.cell(r).record ) );  % record the parameter x of artificial cell tt-1
                                        else
                                            fprintf(ofile,sprintf('io = rec.record(&cellList.o(%d).cell.%s,tvec)\n', tt-1, neuron{refR}.record{t}.cell(r).record ) ); % record the parameter x of artificial cell tt-1
                                        end
                                        if neuron{refPar}.params.cvode
                                            if makenewrect
                                                fprintf(ofile,'io = rectList.append(rect)\n\n' );  %append time recording vector to recList
                                                countt = countt +1;
                                                makenewrect = false;
                                            end
                                            neuron{refR}.record{t}.cell(r).idt = countt;    % reference to find recording in recList
                                        end
                                    end
                                    fprintf(ofile,'io = recList.append(rec)\n\n' );  %append recording vector to recList
                                    neuron{refR}.record{t}.cell(r).id = count;   % reference to find recording in recList
                                    count = count +1;
                            end
                        end
                        fprintf(ofile,'\n');
                    end
                    if neuron{refPar}.params.parallel
                        fprintf(ofile,'}\n');
                    end
                end
            end
            fprintf(ofile, 'objref rec\n');
            fprintf(ofile, 'objref rect\n');
        end
        %
        if ~isnan(refAP)     %rewrite only if record def is not taken from previous sim
            %!%! there might be problems with cvode (not adjusted yet)
            fprintf(ofile,'\n\n');
            fprintf(ofile,'// ***** Define APCount sites *****\n');
            for tt = 1:numel(neuron{n}.tree)
                t = neuron{n}.tree(tt);
                if numel(neuron{refAP}.APCount) >= t && ~isempty(neuron{refAP}.APCount{t})   % if a recording site was defined for  this tree
                    if neuron{refPar}.params.parallel
                        fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                    end
                    for r = 1: size(neuron{refAP}.APCount{t},1)
                        if ~isfield(tree{neuron{n}.tree(tt)},'artificial')
                            inode = find(minterf{neuron{n}.tree(tt)}(:,1) == neuron{refAP}.APCount{t}(r,1),1,'first');    %find the index of the node in minterf
                            fprintf(ofile,sprintf('cellList.o(%d).allregobj.o(%d).sec',tt-1,minterf{neuron{n}.tree(tt)}(inode,2) ) );    % corresponding section of node
                            fprintf(ofile,sprintf('{APC = new APCount(%f)\n',minterf{neuron{n}.tree(tt)}(inode,3) ) );    % make APCCount at position x
                            fprintf(ofile,sprintf('APC.thresh = %f\n',neuron{refAP}.APCount{t}(r,2) ) ); % set threshold of APCount [mV]
                        else
                            fprintf(ofile,sprintf('APC = new NetCon(cellList.o(%d).cell,nil,%g,0,5)\n',tt-1,neuron{refAP}.APCount{t}(r,2) ) );    % for art. cells, make netcon with threshold
                        end
                        fprintf(ofile,'APCrec = new Vector()\n');
                        fprintf(ofile,'io = APCrecList.append(APCrec)\n');
                        fprintf(ofile,'io = APC.record(APCrecList.o(APCrecList.count()-1))\n');
                        
                        if ~isfield(tree{neuron{n}.tree(tt)},'artificial')
                            fprintf(ofile,'io = APCList.append(APC)}\n\n' );  %append recording vector to recList
                        else
                            fprintf(ofile,'io = APCList.append(APC)\n\n' );  %append recording vector to recList
                        end
                    end
                    fprintf(ofile,'\n');
                    if neuron{refPar}.params.parallel
                        fprintf(ofile,'}\n');
                    end
                end
            end
            fprintf(ofile, 'objref APC\n');
            fprintf(ofile, 'objref APCrec\n');
            %             end
        end
        fclose(ofile);
    elseif exist(fullfile(exchfolder,thisfolder,'init_rec.hoc'),'file')
        delete(fullfile(exchfolder,thisfolder,'init_rec.hoc'));
    end
    
    
    %% write init_play.hoc
    
    if (~isnan(refP)) && refP==n      %rewrite only if one or both of play/APCount are not taken from previous sim or if both are taken from another sim but from different ones (not possible because both are in one hoc)
        ofile = fopen(fullfile(exchfolder,thisfolder,'init_play.hoc') ,'wt');   %open play hoc file in write modus
        fprintf(ofile,'\n\n');
        fprintf(ofile,'// ***** Define play sites *****\n');
        count = 0;  % counter for playing vector List
        for tt = 1:numel(neuron{n}.tree)
            t = neuron{n}.tree(tt);
            if numel(neuron{refP}.play) >= t && ~isempty(neuron{refP}.play{t})  % if a playing site was defined for  this tree
                if neuron{refPar}.params.parallel
                    fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                end
                if isfield(tree{neuron{n}.tree(tt)},'artificial')
                    playfields = fieldnames(neuron{refP}.play{t});
                    if numel(playfields) > 1 && strcmp(playfields,'play')
                        neuron{refP}.play{t} = struct(tree{neuron{n}.tree(tt)}.artificial,neuron{refP}.play{t}); % put the structure in field named as the artificial neuron
                    end
                end
                playfields = fieldnames(neuron{refP}.play{t});
                
                for f1 = 1:numel(playfields)
                    if isfield(tree{neuron{n}.tree(tt)},'artificial')
                        playtype = 'artificial';
                    elseif strcmp(playfields{f1},'cell')       % check if playing should be a parameter in a section, or a point process (divided in pps and electrodes)
                        playtype = 'cell';
                    else
                        playtype = 'pp';
                    end
                    
                    for r = 1:numel(neuron{refP}.play{t}.(playfields{f1})) %.play)  % go through all variables to be played
                        if isfield(neuron{n}.play{t}.(playfields{f1})(r),'cont')
                            cont = neuron{n}.play{t}.(playfields{f1})(r).cont;
                        else
                            cont = 0;
                        end
                        if strcmp(playtype,'cell')
                            if isfield(tree{neuron{n}.tree(tt)},'R') && isfield(tree{neuron{n}.tree(tt)},'rnames')
                                Rs = tree{neuron{n}.tree(tt)}.rnames(tree{neuron{n}.tree(tt)}.R(neuron{refP}.play{t}.cell(r).node));       % all region names of trees nodes
                                strs = regexp(neuron{refP}.play{t}.cell(r).play,'_','split');            % split play string to get mechanism name
                                if numel(strs)>1              % check if play variable is variable of a mechanism or maybe global
                                    ignorethese = false(1,numel(neuron{refP}.play{t}.cell(r).node));
                                    uRs = unique(Rs);
                                    str = '';
                                    for u = 1:numel(uRs)                                            % go through regions to be played
                                        if (~isfield(neuron{n}.mech{t},uRs{u}) || isfield(neuron{n}.mech{t},uRs{u}) && ~isfield(neuron{n}.mech{t}.(uRs{u}),strs{end})) &&  (~isfield(neuron{n}.mech{t},'all') || isfield(neuron{n}.mech{t},'all') && ~isfield(neuron{n}.mech{t}.all,strs{end}))             % check if this region also has the mechanism to be played
                                            ignorethese = ignorethese | strcmp(uRs{u},Rs);           % if not ignore these region for playing
                                            str = strcat(str,uRs{u},'/');
                                        end
                                    end
                                    if ~isempty(str)
                                        neuron{refP}.play{t}.cell(r).node(ignorethese) = [];                     % delete the playing nodes which should be ignored
                                        warning('Region(s) "%s" of tree %d do not contain mechanism "%s" for playing. Playing in this region is ignored',str(1:end-1),t,strs{end})
                                    end
                                end
                            end
                        end
                        
                        if ~any(strcmp(playtype,'artificial'))
                            inode = zeros(numel(neuron{refP}.play{t}.(playfields{f1})(r).node),1);
                            for in = 1:numel(neuron{refP}.play{t}.(playfields{f1})(r).node)
                                inode(in) = find(minterf{neuron{n}.tree(tt)}(:,1) == neuron{refP}.play{t}.(playfields{f1})(r).node(in),1,'first');    %find the index of the node in minterf
                            end
                            [realplays,~,ic] = unique(minterf{neuron{n}.tree(tt)}(inode,[2,4]),'rows');
                            % put warning here !
                        end
                        
                        switch playtype
                            case 'cell'
                                for in = 1:size(realplays,1)
                                    
                                    fprintf(ofile,sprintf('playt = new Vector(%f)\n',length(neuron{n}.play{t}.(playfields{f1})(r).times) ));    % create new playing time vector
                                    %a file needs to be created to temporally save the vector so
                                    %NEURON can read it in. otherwise it would be necessary to
                                    %print the whole vector into the hoc file. alternatively i
                                    %could give a file name where the vector lies so it is not
                                    %written each time cn is called...
                                    f = fopen(fullfile(exchfolder,thisfolder,sprintf('plt_%s_at_%d_cell_%d.dat', neuron{n}.play{t}.(playfields{f1})(r).play , ic(in) ,tt-1)),'w');
                                    fprintf(f,'%g ', neuron{n}.play{t}.(playfields{f1})(r).times(1:end-1));
                                    fprintf(f,'%g\n', neuron{n}.play{t}.(playfields{f1})(r).times(end));
                                    fclose(f);
                                    fprintf(ofile,'f = new File()\n');
                                    fprintf(ofile,sprintf('f.ropen("plt_%s_at_%d_cell_%d.dat")\n', neuron{n}.play{t}.(playfields{f1})(r).play  , ic(in),tt-1));  %vector file is opened
                                    fprintf(ofile,'playt.scanf(f)\n');    % file is read into time vector
                                    fprintf(ofile,'io = f.close()\n');     %file is closed
                                    fprintf(ofile,'io = playtList.append(playt)\n\n' );  %append playing time vector to playtList
                                    
                                    fprintf(ofile,sprintf('play = new Vector(%f)\n',length(neuron{n}.play{t}.(playfields{f1})(r).value) ) );    % create new playing vector
                                    f = fopen(fullfile(exchfolder,thisfolder,sprintf('pl_%s_at_%d_cell_%d.dat', neuron{n}.play{t}.(playfields{f1})(r).play , ic(in) ,tt-1)),'w');
                                    fprintf(f,'%g ', neuron{n}.play{t}.(playfields{f1})(r).value(1:end-1));
                                    fprintf(f,'%g\n', neuron{n}.play{t}.(playfields{f1})(r).value(end));
                                    fclose(f);
                                    fprintf(ofile,'f = new File()\n');
                                    fprintf(ofile,sprintf('f.ropen("pl_%s_at_%d_cell_%d.dat")\n', neuron{n}.play{t}.(playfields{f1})(r).play , ic(in) ,tt-1));  %vector file is opened
                                    fprintf(ofile,'play.scanf(f)\n');     % file is read into play vector
                                    fprintf(ofile,'io = f.close()\n');   %file is closed
                                    fprintf(ofile,sprintf('play.label("playing %s at node %d of cell %d")\n', neuron{n}.play{t}.(playfields{f1})(r).play  , ic(in) ,tt-1) ); % label the vector for plotting
                                    fprintf(ofile,sprintf('play.play(&cellList.o(%d).allregobj.o(%d).sec.%s(%f),playtList.o(playtList.count()-1),%d)\n',tt-1,realplays(in,1), neuron{n}.play{t}.(playfields{f1})(r).play, realplays(in,2), cont ) ); % play the parameter x at site y as specified in neuron{n}.play
                                    fprintf(ofile,'io = playList.append(play)\n\n' );  %append playing vector to playList
                                    
                                end
                            case 'pp'
                                if isfield(neuron{refP}.play{t}.(playfields{f1})(r),'ppg')
                                    ppg = neuron{refP}.play{t}.(playfields{f1})(r).ppg;
                                elseif numel(neuron{refPP}.pp{t}.(playfields{f1})) == numel(neuron{refP}.play{t}.(playfields{f1}))
                                    ppg = r;
                                else
                                    ppg =1;
                                end
                                for in =  1:numel(inode)%size(realplays,1)%numel(neuron{refP}.play{t}{r,1})  % CAUTION might be wrong
                                    ind = find(neuron{refPP}.pp{t}.(playfields{f1})(ppg).node == neuron{refP}.play{t}.(playfields{f1})(r).node(in));  % check if node really has the corresponding PP
                                    if ~isempty(ind)
                                        fprintf(ofile,sprintf('playt = new Vector(%f)\n',length(neuron{n}.play{t}.(playfields{f1})(r).times) ));    % create new playing time vector
                                        %a file needs to be created to temporally save the vector so
                                        %NEURON can read it in. otherwise it would be necessary to
                                        %print the whole vector into the hoc file. alternatively i
                                        %could give a file name where the vector lies so it is not
                                        %written each time cn is called...
                                        f = fopen(fullfile(exchfolder,thisfolder,sprintf('plt_%s_%s_at_%d_cell_%d.dat', playfields{f1}, neuron{n}.play{t}.(playfields{f1})(r).play , ic(in) ,tt-1)),'w');
                                        if ~any(size(neuron{n}.play{t}.(playfields{f1})(r).times)==1) % it's a matrix
                                            if size(neuron{n}.play{t}.(playfields{f1})(r).times,1) == numel(inode)
                                                fprintf(f,'%g ', neuron{n}.play{t}.(playfields{f1})(r).times(in,1:end-1));
                                                fprintf(f,'%g\n', neuron{n}.play{t}.(playfields{f1})(r).times(in,end));
                                            else
                                                for nn = 1:numel(neuron)
                                                    delete(fullfile(exchfolder,sprintf('sim%d',nn),'iamrunning'));   % delete the running mark
                                                end
                                                error('Times vector of play feature has wrong size')
                                            end
                                        else
                                            fprintf(f,'%g ', neuron{n}.play{t}.(playfields{f1})(r).times(1:end-1));
                                            fprintf(f,'%g\n', neuron{n}.play{t}.(playfields{f1})(r).times(end));
                                        end
                                        fclose(f);
                                        fprintf(ofile,'f = new File()\n');
                                        fprintf(ofile,sprintf('f.ropen("plt_%s_%s_at_%d_cell_%d.dat")\n', playfields{f1}, neuron{n}.play{t}.(playfields{f1})(r).play  , ic(in),tt-1));  %vector file is opened
                                        fprintf(ofile,'playt.scanf(f)\n');    % file is read into time vector
                                        fprintf(ofile,'io = f.close()\n');     %file is closed
                                        fprintf(ofile,'io = playtList.append(playt)\n\n' );  %append playing time vector to playtList
                                        
                                        fprintf(ofile,sprintf('play = new Vector(%f)\n',length(neuron{n}.play{t}.(playfields{f1})(r).value) ) );    % create new playing vector
                                        f = fopen(fullfile(exchfolder,thisfolder,sprintf('pl_%s_%s_at_%d_cell_%d.dat', playfields{f1}, neuron{n}.play{t}.(playfields{f1})(r).play , ic(in) ,tt-1)),'w');
                                        fprintf(f,'%g ', neuron{n}.play{t}.(playfields{f1})(r).value(1:end-1));
                                        fprintf(f,'%g\n', neuron{n}.play{t}.(playfields{f1})(r).value(end));
                                        fclose(f);
                                        fprintf(ofile,'f = new File()\n');
                                        fprintf(ofile,sprintf('f.ropen("pl_%s_%s_at_%d_cell_%d.dat")\n', playfields{f1}, neuron{n}.play{t}.(playfields{f1})(r).play , ic(in) ,tt-1));  %vector file is opened
                                        fprintf(ofile,'play.scanf(f)\n');     % file is read into play vector
                                        fprintf(ofile,'io = f.close()\n');   %file is closed
                                        fprintf(ofile,sprintf('play.label("playing %s %s at node %d of cell %d")\n', playfields{f1}, neuron{n}.play{t}.(playfields{f1})(r).play  , ic(in) ,tt-1) ); % label the vector for plotting
                                        fprintf(ofile,sprintf('io = play.play(&ppList.o(%d).%s,playt)\n',neuron{refPP}.pp{t}.(playfields{f1})(ppg).id(ind), neuron{refP}.play{t}.(playfields{f1})(r).play ) ); % play the parameter x at site y as specified in neuron{refP}.play
                                        fprintf(ofile,'io = playList.append(play)\n\n' );  %append playing vector to playList
                                        
                                        neuron{refP}.play{t}.(playfields{f1})(r).id(in) = count;   % reference to find playing in playList
                                        count = count +1;
                                    else
                                        neuron{refP}.play{t}.(playfields{f1})(r).id(in) = NaN;   % reference to find playing in playList
                                        fprintf('Node %d of cell %d does not comprise the PP "%s". Playing is ignored.',neuron{refP}.play{t}.(playfields{f1})(r).node(in),t,playfields{f1})
                                    end
                                end
                            case 'artificial'
                                fprintf(ofile,sprintf('playt = new Vector(%f)\n',length(neuron{n}.play{t}.(playfields{f1})(r).times) ));    % create new playing time vector
                                %a file needs to be created to temporally save the vector so
                                %NEURON can read it in. otherwise it would be necessary to
                                %print the whole vector into the hoc file. alternatively i
                                %could give a file name where the vector lies so it is not
                                %written each time cn is called...
                                if strcmp(tree{neuron{n}.tree(tt)}.artificial,'VecStim') && any(neuron{n}.play{t}.(playfields{f1})(r).times < 0)
                                    neuron{n}.play{t}.(playfields{f1})(r).times(neuron{n}.play{t}.(playfields{f1})(r).times < 0) = [];
                                    disp('Warning, VecStim should not receive negative play times. These are deleted now')
                                end
                                f = fopen(fullfile(exchfolder,thisfolder,sprintf('plt_%s_of_art_%s_cell%d.dat', neuron{n}.play{t}.(playfields{f1})(r).play, playfields{f1}, tt-1)),'w');
                                fprintf(f,'%g ', neuron{n}.play{t}.(playfields{f1})(r).times(1:end-1));
                                fprintf(f,'%g\n', neuron{n}.play{t}.(playfields{f1})(r).times(end));
                                fclose(f);
                                fprintf(ofile,'f = new File()\n');
                                fprintf(ofile,sprintf('f.ropen("plt_%s_of_art_%s_cell%d.dat")\n',  neuron{n}.play{t}.(playfields{f1})(r).play, playfields{f1}, tt-1));  %vector file is opened
                                fprintf(ofile,'playt.scanf(f)\n');    % file is read into time vector
                                fprintf(ofile,'io = f.close()\n');     %file is closed
                                fprintf(ofile,'io = playtList.append(playt)\n\n' );  %append playing time vector to playtList
                                if ~strcmp(neuron{n}.play{t}.(playfields{f1})(r).play,'spike') && ~strcmp(playfields{f1},'VecStim')
                                    fprintf(ofile,sprintf('play = new Vector(%f)\n',length(neuron{n}.play{t}.(playfields{f1})(r).value) ) );    % create new playing vector
                                    f = fopen(fullfile(exchfolder,thisfolder,sprintf('plt_%s_of_art_%s_cell%d.dat', neuron{n}.play{t}.(playfields{f1})(r).play, playfields{f1}, tt-1)),'w');
                                    fprintf(f,'%g ', neuron{n}.play{t}.(playfields{f1})(r).value(1:end-1));
                                    fprintf(f,'%g\n', neuron{n}.play{t}.(playfields{f1})(r).value(end));
                                    fclose(f);
                                    fprintf(ofile,'f = new File()\n');
                                    fprintf(ofile,sprintf('f.ropen("plt_%s_of_art_%s_cell%d.dat")\n', neuron{n}.play{t}.(playfields{f1})(r).play, playfields{f1}, tt-1));  %vector file is opened
                                    fprintf(ofile,'play.scanf(f)\n');     % file is read into play vector
                                    fprintf(ofile,'io = f.close()\n');   %file is closed
                                    fprintf(ofile,sprintf('play.label("%s of artificial cell %s (cell #%d)")\n', neuron{refP}.play{t}.cell(r).play , tree{neuron{n}.tree(tt)}.artificial, tt-1) ); % label the vector for plotting
                                    warning('not tested yet play')
                                    fprintf(ofile,sprintf('io = cellList.o(%d).cell.play(&,playt)\n',tt-1, neuron{refP}.play{t}.(playfields{f1})(r).play ) ); % play the parameter x at site y as specified in neuron{refP}.play
                                    fprintf(ofile,'io = playList.append(play)\n\n' );  %append playing vector to playList
                                else
                                    fprintf(ofile,sprintf('io = cellList.o(%d).cell.play(playt)\n',tt-1 ) ); % the vecstim has its own play class
                                end
                                
                                neuron{refP}.play{t}.cell(r).id = count;   % reference to find playing in playList
                                count = count +1;
                                
                        end
                    end
                    fprintf(ofile,'\n');
                end
                if neuron{refPar}.params.parallel
                    fprintf(ofile,'}\n');
                end
            end
        end
        fprintf(ofile, 'objref play\n');
        fprintf(ofile, 'objref playt\n');
        %
        fclose(ofile);
    elseif exist(fullfile(exchfolder,thisfolder,'init_play.hoc'),'file')
        delete(fullfile(exchfolder,thisfolder,'init_play.hoc'));
    end
    
    %% write save_rec.hoc
    
    ofile = fopen(fullfile(exchfolder,thisfolder,'save_rec.hoc') ,'wt');   %open record hoc file in write modus
    fprintf(ofile,'// * Write Recordings to Files *\n');
    if ~isnan(refR)
        makenewrect = true;
        out{n}.record = cell(1,numel(neuron{n}.tree));   % initialize output of cn
        
        for tt = 1:numel(neuron{n}.tree)
            t = neuron{n}.tree(tt);
            if neuron{refPar}.params.use_local_dt
                makenewrect = true;
            end
            if numel(neuron{refR}.record) >= t && ~isempty(neuron{refR}.record{t})
                if neuron{refPar}.params.parallel
                    fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                end
                %                 for r = 1: size(neuron{refR}.record{t},1)
                recfields = fieldnames(neuron{refR}.record{t});
                
                for f1 = 1:numel(recfields)
                    if isfield(tree{neuron{n}.tree(tt)},'artificial')
                        rectype = 'artificial';
                    elseif strcmp(recfields{f1},'cell')     % check if recording should be a parameter in a section, or a point process (divided in pps and electrodes)
                        rectype = 'cell';
                    else
                        rectype = 'pp';
                    end
                    
                    for r = 1:numel(neuron{refR}.record{t}.(recfields{f1}))   % go through all variables to be recorded
                        
                        
                        switch rectype
                            case 'cell'
                                for in = 1:size(neuron{refR}.record{t}.cell(r).rrecs,1)
                                    fname = sprintf('cell%d_sec%d_loc%06.4f_%s', tt-1, neuron{refR}.record{t}.cell(r).rrecs(in,:), neuron{refR}.record{t}.(recfields{f1})(r).record  );
                                    fprintf(ofile,'save_rec("%s.dat",%d)\n',fname,neuron{refR}.record{t}.(recfields{f1})(r).id(in));
                                    noutfiles = noutfiles +1;
                                    readfiles{noutfiles} = {sprintf('%s.dat',fname), n, t , 'cell', neuron{refR}.record{t}.(recfields{f1})(r).record , neuron{refR}.record{t}.(recfields{f1})(r).node(neuron{refR}.record{t}.(recfields{f1})(r).irrecs == in) }; %neuron{refR}.record{t}.(recfields{f1})(r).node(in) };
                                end
                            case 'pp'
                                for in = 1:size(neuron{refR}.record{t}.(recfields{f1})(r).rrecs,1)
                                    if ~isnan(neuron{refR}.record{t}.(recfields{f1})(r).id(in))  % if recording has not been deleted because the PP did not exist at that place
                                        fname = sprintf('%s_cell%d_sec%d_loc%06.4f_%s',recfields{f1},tt-1, neuron{refR}.record{t}.(recfields{f1})(r).rrecs(in,:), neuron{refR}.record{t}.(recfields{f1})(r).record  );
                                        fprintf(ofile,'save_rec("%s.dat",%d)\n',fname,neuron{refR}.record{t}.(recfields{f1})(r).id(in));
                                        noutfiles = noutfiles +1;
                                        readfiles{noutfiles} = {sprintf('%s.dat',fname), n, t , recfields{f1}, neuron{refR}.record{t}.(recfields{f1})(r).record , neuron{refR}.record{t}.(recfields{f1})(r).node(neuron{refR}.record{t}.(recfields{f1})(r).irrecs == in)};%neuron{refR}.record{t}.(recfields{f1})(r).node(in) };
                                    end
                                end
                            case 'artificial'
                                fname = sprintf('cell%d_%s',tt-1, neuron{refR}.record{t}.(recfields{f1})(r).record );
                                fprintf(ofile,'save_rec("%s.dat",%d)\n',fname,neuron{refR}.record{t}.(recfields{f1})(r).id);
                                noutfiles = noutfiles +1;
                                readfiles{noutfiles} = {sprintf('%s.dat',fname), n, t , 'cell', neuron{refR}.record{t}.(recfields{f1})(r).record , 1 };
                        end
                        if neuron{refPar}.params.cvode && makenewrect  % save tvector once (or for each cell if local dt)
                            if neuron{refPar}.params.use_local_dt
                                fnamet = sprintf('cell%d_tvec.dat', tt-1);
                            else
                                fnamet = 'tvec.dat';
                            end
                            fprintf(ofile,'save_rect("%s",%d)\n',fnamet,neuron{refR}.record{t}.(recfields{f1})(r).idt(1));
                            makenewrect = false;
                        end
                    end
                end
                if neuron{refPar}.params.parallel
                    fprintf(ofile,'}\n');
                end
            end
        end
        fprintf(ofile,'\n');
    end
    fprintf(ofile,'// * Write APCounts to Files *\n');
    
    if ~isnan(refAP)
        c=0;
        for tt = 1:numel(neuron{n}.tree)
            t = neuron{n}.tree(tt);
            if numel(neuron{refAP}.APCount) >= t && ~isempty(neuron{refAP}.APCount{t})     % if a recording site was defined for  this tree
                if neuron{refPar}.params.parallel
                    fprintf(ofile,'if (pc.gid_exists(%d)) {\n',tt-1);
                end
                for r = 1: size(neuron{refAP}.APCount{t},1)
                    fname = sprintf('cell%d_node%d_APCtimes.dat',tt-1,neuron{refAP}.APCount{t}(r,1) );
                    fprintf(ofile,'f = new File()\n');      %create a new filehandle
                    fprintf(ofile,sprintf('io = f.wopen("%s//%s//%s")\n',nrn_exchfolder,thisfolder,fname) );  % open file for this vector with write perm.
                    fprintf(ofile,sprintf('io = APCrecList.o(%d).printf(f, "%%%%-20.10g")\n', c ) );    % print the data of the vector into the file
                    fprintf(ofile,'io = f.close()\n');   %close the filehandle
                    
                    c= c+1;
                    noutfiles = noutfiles +1;
                    readfiles{noutfiles} = {fname, n, t , 'APCtimes', 'times' , neuron{refAP}.APCount{t}(r,1)};
                end
                fprintf(ofile,'\n');
                if neuron{refPar}.params.parallel
                    fprintf(ofile,'}\n');
                end
            end
        end
    end
    fclose(ofile);
    
    
    if ~isempty(strfind(options,'-cl')) %transfer files to server
        filenames = {interf_file,'init_cells.hoc','init_mech.hoc','init_pp.hoc','init_con.hoc','init_rec.hoc','save_rec.hoc','init_play.hoc'}; %'init_pas.hoc','init_stim.hoc'
        m = 1;
        localfilename{m} = fullfile(exchfolder,thisfolder,filenames{1});
        remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,filenames{1});
        m = m + 1;
        if usestreesof(n) == n
            localfilename{m} = fullfile(exchfolder,thisfolder,filenames{2});
            remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,filenames{2});
            m = m + 1;
        end
        if  t2n_getref(n,neuron,'mech') == n
            localfilename{m} = fullfile(exchfolder,thisfolder,filenames{3});
            remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,filenames{3});
            m = m + 1;
        end
        if t2n_getref(n,neuron,'pp') == n
            localfilename{m} = fullfile(exchfolder,thisfolder,filenames{4});
            remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,filenames{4});
            m = m + 1;
        end
        if t2n_getref(n,neuron,'con') == n
            localfilename{m} = fullfile(exchfolder,thisfolder,filenames{5});
            remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,filenames{5});
            m = m + 1;
        end
        if t2n_getref(n,neuron,'record') == n
            localfilename{m} = fullfile(exchfolder,thisfolder,filenames{6});
            remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,filenames{6});
            m = m + 1;
            localfilename{m} = fullfile(exchfolder,thisfolder,filenames{7});
            remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,filenames{7});
            m = m + 1;
        end
        if t2n_getref(n,neuron,'play') == n
            localfilename{m} = fullfile(exchfolder,thisfolder,filenames{8});
            remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,filenames{8});
            m = m + 1;
        end
        %create job
        ofile = fopen(fullfile(exchfolder,thisfolder,'start_nrn.pbs') ,'wt');
        fprintf(ofile,'#!/bin/tcsh\n');
        fprintf(ofile,'# set job variables\n');
        fprintf(ofile,'#$ -S /bin/tcsh\n');
        fprintf(ofile,'#$ -j n\n');
        fprintf(ofile,'#$ -e %s/%s/ErrorLogFile.txt\n',nrn_exchfolder,thisfolder);
        fprintf(ofile,'#$ -o %s/%s/NeuronLogFile.txt\n',nrn_exchfolder,thisfolder);
        fprintf(ofile,'#$ -pe openmp 1\n');
        fprintf(ofile,sprintf('#$ -l h_rt=%02d:%02d:%02d\n',server.walltime));
        fprintf(ofile,sprintf('#$ -l h_rt=%02d:%02d:%02d\n',server.softwalltime));
        fprintf(ofile,sprintf('#$ -l h_vmem=%02dG\n',server.memory));
        fprintf(ofile,sprintf('#$ -N nrn_%s\n',thisfolder));  % name of job
        fprintf(ofile,'# load needed modules \n');
        fprintf(ofile,sprintf('module load %s \n',regexprep(server.neuron{1},'\r\n|\n|\r',''))); % load first found neuron version
        
        fprintf(ofile,'# start program\n');
        fprintf(ofile,sprintf('nrniv -nobanner -nogui -dll "%s" "%s/%s/%s"\n',server.nrnmech,nrn_exchfolder,thisfolder,interf_file));
        fclose(ofile);
        localfilename{m} = fullfile(exchfolder,thisfolder,'start_nrn.pbs');
        remotefilename{m} = sprintf('%s/%s/%s',nrn_exchfolder,thisfolder,'start_nrn_pre.pbs');
        sftpfrommatlab(server.user,server.host,server.pw,localfilename,remotefilename);
        [server.connect,~] = sshfrommatlabissue(server.connect,sprintf('tr -d ''\r'' < %s/%s/start_nrn_pre.pbs > %s/%s/start_nrn.pbs',nrn_exchfolder,thisfolder,nrn_exchfolder,thisfolder)); % delete carriage returns (windows)
    end
    
    if strfind(options,'-d')
        tim = toc(tim);
        fprintf(sprintf('Sim %d: HOC writing time: %g min %.2f sec\n',n,floor(tim/60),rem(tim,60)))
    end
    
end

%% Execute NEURON
if ~isempty(strfind(options,'-cl'))
    num_cores = 500;  % use evt qstat -f?
else
    num_cores = feature('numCores');
end
if ~isempty(strfind(options,'-nc'))
    nc = str2double(regexp(options,'(?<=-nc)[0-9]*', 'match'));
    if num_cores < nc
        warning('%d cores have been assigned to T2N, however only %d physical cores where detected. Defining more cores might slow down PC and simulations',neuron{refPar}.params.numCores,num_cores)
    end
    num_cores = nc;
end

simids = zeros(numel(neuron),1); % 0 = not run, 1 = running, 2 = finished, 3 = error
jobid = simids;
for s = 1:num_cores
    r = find(simids==0,1,'first');
    if ~isempty(r)
        [jobid(r),tim] = exec_neuron(r,exchfolder,nrn_exchfolder,interf_file,options);
        simids(r) = 1;
    else
        break
    end
end

if noutfiles > 0 % if output is expected
    % wait for the NEURON process to be finished as indicated by appearance of
    % a file called 'readyflag' in the exchfolder; should be created in the last
    % line of the NEURON program
    if isempty(strfind(options,'-q'))
        disp('waiting for NEURON to finish...')
    end
    if ~isempty(strfind(options,'-w'))
        w = waitbar(0,'Neuron Simulations are running, please wait');
    end
    timm = tic;
    while ~all(simids>1)
        if ~isempty(strfind(options,'-cl'))
            pause(30); % wait for 30 seconds
            [server.connect,answer] = sshfrommatlabissue(server.connect,sprintf('%s %sqstat -u %s',server.envstr,server.qfold,server.user));
            if isempty(answer.StdOut)
                answer = {{''}};
            else
                answer = textscan(answer.StdOut,'%s','Delimiter','\n');
            end
            currjobs = find(simids==1);
            for ss = 1:numel(currjobs)
                s = currjobs(ss);
                if any(~cellfun(@isempty,regexp(answer{1},num2str(jobid(s)),'ONCE')))     %job not finished yet
                    ind = ~cellfun(@isempty,regexp(answer{1},num2str(jobid(s)),'ONCE'));
                    jobanswer = textscan(answer{1}{ind},'%s','Delimiter',' ');%[ qw]');%'[qw|r|t] ');
                    jobanswer = jobanswer{1}(~cellfun(@isempty,jobanswer{1}));
                    jobstate = jobanswer{5};
                    switch jobstate
                        case 'r'
                            jobstate = 'running';
                        otherwise
                            jobstate = 'waiting';
                    end
                    fprintf('Simulation %d is still %s on cluster, since %s %s',s,jobstate,jobanswer{6},jobanswer{7})
                    
                else   % job is finished
                    fprintf('Simulation %d has finished',s)
                    simids(s) = 2;              % mark that simulation as finished
                    r = find(simids==0,1,'first');  % find next not runned simid
                    if ~isempty(r)
                        jobid(r) = exec_neuron(r,exchfolder,nrn_exchfolder,interf_file,options);          % start new simulation
                        simids(r) = 1;          % mark this as running
                    end
                end
            end
        else
            s = find(simids==1);
            for ss = 1:numel(s)
                r = exist(fullfile(exchfolder,sprintf('sim%d',s(ss)),'readyflag'),'file');  % becomes 1 (still running) if not existing, or 2 (finished)
                if r == 2
                    simids(s(ss)) = 2;              % mark that simulation as finished
                    r = find(simids==0,1,'first');  % find next not runned simid
                    if ~isempty(r)
                        [jobid(r),tim] = exec_neuron(r,exchfolder,nrn_exchfolder,interf_file,options);          % start new simulation
                        simids(r) = 1;          % mark this as running
                    end
                elseif exist(fullfile(exchfolder,sprintf('sim%d',s(ss)),'ErrorLogFile.txt'),'file') == 2
                    finfo = dir(fullfile(exchfolder,sprintf('sim%d',s(ss)),'ErrorLogFile.txt'));
                    if finfo.bytes > 0      % because error file log is always built
                        f = fopen(fullfile(exchfolder,sprintf('sim%d',s(ss)),'ErrorLogFile.txt'));
                        txt = fscanf(f,'%c');
                        fclose(f);
                        errordlg(sprintf('There was an error in Simulation %d (and maybe others):\n******************************\n%s\n******************************\nDue to that t2n has no output to that Simulation.',s(ss),txt(1:min(numel(txt),2000))),'Error in NEURON','replace');
                        simids(s(ss)) = 3;
                        r = find(simids==0,1,'first');  % find next not runned simid
                        if ~isempty(r)
                            [jobid(r),tim] = exec_neuron(r,exchfolder,nrn_exchfolder,interf_file,options);          % start new simulation
                            simids(r) = 1;          % mark this as running
                        end
                    end
                end
            end
            pause(0.1);
        end
        if ~isempty(strfind(options,'-w'))
            if ishandle(w)
                if any(simids>1)
                    waitbar(sum(simids>1)/numel(simids),w);
                end
            else
                answer = questdlg(sprintf('Waitbar was closed, t2n stopped continuing. Only finished data is returned. If accidently, retry.\nClose all NEURON instances?\n (Caution if several Matlab instances are running)'),'Close NEURON instances?','Close','Ignore','Ignore');
                if strcmp(answer,'Close')
                    if isempty(strfind(options,'-cl'))
                        if ispc
                            system('taskkill /F /IM nrniv.exe');
                        else
                            system('pkill -9 "nrniv"');
                        end
                    else
                        
                    end
                end
                simids(simids<2) = 4;
                fclose all;
            end
        end
    end
    
    if ~isempty(strfind(options,'-cl'))
        s = find(simids==2);
        
        for ss = 1:numel(s)
            [server.connect,answer] = sshfrommatlabissue(server.connect,sprintf('ls %s/%s/readyflag',nrn_exchfolder,sprintf('sim%d',s(ss))));
            if isempty(answer.StdOut)    % then there was an error during executing NEURON
                [server.connect,answer] = sshfrommatlabissue(server.connect,sprintf('cat %s/%s/ErrorLogFile.txt',nrn_exchfolder,sprintf('sim%d',s(ss))));
                if ~isempty(answer.StdOut)
                    error('There was an error during NEURON simulation #%d:\n%s\n',s(ss),answer.StdOut)
                else
                    error('There was an unknown error during job execution of simulation #%d. Probably job got deleted?',s(ss))
                end
            end
        end
    end
    
    if ~isempty(strfind(options,'-d'))
        tim = toc(timm);
        fprintf(sprintf('NEURON execute time: %g min %.2f sec\n',floor(tim/60),rem(tim,60)))
    end
    if isempty(strfind(options,'-q'))
        disp('NEURON finished... loading data...')
    end
    if ~isempty(strfind(options,'-w')) && ishandle(w)
        close(w)
    end
    if strfind(options,'-d')
        tim = tic;
    end
    if ~isempty(strfind(options,'-cl'))
        remotefilename = cellfun(@(y) strcat(nrn_exchfolder,sprintf('/sim%d/',y{2}),y{1}),readfiles,'UniformOutput',0);  % extract filenames
        localfilename = cellfun(@(x) fullfile(modelFolder,x(regexp(x,exchfolder,'start'):end)),remotefilename,'UniformOutput',0);
        sftptomatlab(server.user,server.host,server.pw,remotefilename,localfilename)
    end
    
    
    
    % load time vector from NEURON (necessary because of roundoff errors
    if ~isempty(strfind(options,'-cl'))
        remotefilename = arrayfun(@(x) regexprep(fullfile(server.modelfolder,exchfolder,sprintf('sim%d',x),'tvec.dat'),'\\','/'),1:numel(simids),'UniformOutput',0);
        localfilename = cellfun(@(x) fullfile(modelFolder,x(regexp(x,exchfolder,'start'):end)),remotefilename,'UniformOutput',0);
        sftptomatlab(server.user,server.host,server.pw,remotefilename,localfilename)
    end
    for s = 1:numel(simids)
        refPar = t2n_getref(s,neuron,'params');
        if ~neuron{refPar}.params.cvode
            if s~=refPar && isfield(out{refPar},'t')
                out{s}.t = out{refPar}.t;   % just use tvec of simulation with same parameters
            else
                fn = fullfile(exchfolder,sprintf('sim%d',s),'tvec.dat');
                out{s}.t = load(fn,'-ascii');
            end
        end
    end
    
    %% Receive files from Neuron
    if ~isempty(strfind(options,'-w'))
        w = waitbar(0,'Loading files, please wait');
    end
    for f = 1:noutfiles
        refPar = t2n_getref(readfiles{f}{2},neuron,'params');
        if simids(readfiles{f}{2}) == 2    % if there was no error during simulation
            fn = fullfile(exchfolder,sprintf('sim%d',readfiles{f}{2}),readfiles{f}{1});
            if numel(readfiles{f}{6}) > 1
                warning('Recording of %s in %s has %d redundant values since nodes are in same segment.\n',readfiles{f}{5},readfiles{f}{4},numel(readfiles{f}{6}))
            end
            switch readfiles{f}{4}
                case 'APCtimes'
                    out{readfiles{f}{2}}.APCtimes{readfiles{f}{3}}(readfiles{f}{6}) = repmat({load(fn,'-ascii')},numel(readfiles{f}{6}),1);
                otherwise
                    out{readfiles{f}{2}}.record{readfiles{f}{3}}.(readfiles{f}{4}).(readfiles{f}{5})(readfiles{f}{6}) = repmat({load(fn,'-ascii')},numel(readfiles{f}{6}),1);
                    if neuron{refPar}.params.cvode
                        if neuron{refPar}.params.use_local_dt  % if yes, dt was different for each cell, so there is more than one time vector
                            if numel(out{readfiles{f}{2}}.t) < readfiles{f}{3} || isempty(out{readfiles{f}{2}}.t{readfiles{f}{3}})
                                out{readfiles{f}{2}}.t{readfiles{f}{3}} = load(fullfile(exchfolder,sprintf('sim%d',readfiles{f}{2}),sprintf('cell%d_tvec.dat', find(readfiles{f}{3} == neuron{n}.tree)-1)),'-ascii');    %loading of one time vector file per cell (sufficient)
                            end
                        elseif ~isfield(out{readfiles{f}{2}},'t')       % if it has not been loaded in a previous loop
                            out{readfiles{f}{2}}.t = load(fullfile(exchfolder,sprintf('sim%d',readfiles{f}{2}),'tvec.dat'),'-ascii');    %loading of one time vector file at all (sufficient)
                        end
                        out{readfiles{f}{2}}.t(find(diff(out{readfiles{f}{2}}.t,1) == 0) + 1) = out{readfiles{f}{2}}.t(find(diff(out{readfiles{f}{2}}.t,1) == 0) + 1) + 1e-10;  % add tiny time step to tvec to avoid problems with step functions
                    end
            end
            delete(fn)  % delete dat file after loading
        elseif simids(readfiles{f}{2}) == 4  % t2n was aborted
            out{readfiles{f}{2}}.error = 2;
        else
            out{readfiles{f}{2}}.error = 1;
        end
        if ~isempty(strfind(options,'-w'))
            if ishandle(w)
                waitbar(f/noutfiles,w);
            else
                answer = questdlg(sprintf('Waitbar has been closed during data loading. If accidently, retry.\nClose all NEURON instances?\n (Caution if several Matlab instances are running)'),'Close NEURON instances?','Close','Ignore','Ignore');
                if strcmp(answer,'Close')
                    system('taskkill /F /IM nrniv.exe');
                end
                fclose all;
                for n = 1:numel(neuron)
                    delete(fullfile(exchfolder,sprintf('sim%d',n),'iamrunning'));   % delete the running mark
                end
                return
            end
            
        end
    end
    
    if isempty(strfind(options,'-q'))
        disp('data sucessfully loaded')
    end
    if ~isempty(strfind(options,'-w'))
        close(w)
    end
    if strfind(options,'-d')
        tim = toc(tim);
        fprintf(sprintf('Data loading time: %g min %.2f sec\n',floor(tim/60),rem(tim,60)))
    end
    
end
if nocell
    out = out{1};
end
for n = 1:numel(neuron)
    delete(fullfile(exchfolder,sprintf('sim%d',n),'iamrunning'));   % delete the running mark
end

    function [jobid,tim] = exec_neuron(simid,exchfolder,nrn_exchfolder,interf_file,options)
        %% Execute NEURON
        tim = tic;
        
        if ~isempty(simid)
            % execute the file in neuron:
            fname = regexprep(fullfile(exchfolder,sprintf('sim%d',simid),interf_file),'\\','/');
            if ~isempty(strfind(options,'-cl'))
                [server.connect,answer] = sshfrommatlabissue(server.connect,sprintf('%s%sqsub -p 0 %s/%s/%s',server.envstr,server.qfold,nrn_exchfolder,sprintf('sim%d',simid),'start_nrn.pbs'));
                fprintf(sprintf('Answer server after submitting:\n%s\n%s\nExtracing Job Id and wait..\n',answer.StdOut,answer.StdErr))
            else
                if ispc
                    if ~isempty(strfind(options,'-o'))
                        system(['start ' nrnivPath ' -nobanner "' fname sprintf('" > "%s/sim%d/NeuronLogFile.txt" 2> "%s/sim%d/ErrorLogFile.txt"',exchfolder,simid,exchfolder,simid)]); %&,char(13),'exit&']); %nrniv statt neuron
                    else
                        system(['start /B ' nrnivPath ' -nobanner -nogui "' fname sprintf('" -c quit() > "%s/sim%d/NeuronLogFile.txt" 2> "%s/sim%d/ErrorLogFile.txt"',exchfolder,simid,exchfolder,simid)]); %&,char(13),'exit&']); %nrniv statt neuron
                    end
                else
                    %             $ mpiexec ?np 4 $HOME/neuron/nrn-5.9/$CPU/bin/nrniv ?mpi test0.hoc
                    if ~isempty(strfind(options,'-o'))
                        system([sprintf('echo ''cd "%s/lib_mech"; nrniv -nobanner "',modelFolder), fname,sprintf('" -''> "%s/sim%d/startNeuron.sh";chmod +x "%s/sim%d/startNeuron.sh";open -a terminal "%s/sim%d/startNeuron.sh"',exchfolder,simid,exchfolder,simid,exchfolder,simid)]);
                    else
                        system([sprintf('cd "%s/lib_mech"; nrniv -nobanner -nogui "',modelFolder) fname sprintf('" -c "quit()" > "%s/sim%d/NeuronLogFile.txt" 2> "%s/sim%d/ErrorLogFile.txt"',exchfolder,simid,exchfolder,simid),'&']);
                    end
                end
                %         system(['wmic process call create ''', nrnivPath, ' -nobanner "', fname, '" -c quit() ''',sprintf(' > "%s/sim%d/NeuronLogFile.txt" 2> "%s/sim%d/ErrorLogFile.txt"',exchfolder,simid,exchfolder,simid) ]);
                %         f = fopen(sprintf('%s/sim%d/NeuronLogFile.txt',exchfolder,simid));
                %         txt = fscanf(f,'%c');
                %         fclose(f);
                %         txt
            end
            
            
            if ~isempty(strfind(options,'-cl'))
                if ~isempty(answer.StdOut)
                    str = regexp(answer.StdOut,'Your job [0-9]*','match','ONCE');
                    jobid = str2double(str(10:end));%{ind}
                    % there might be error if many jobs are run, because answer might not
                    % be 1
                else
                    jobid = NaN;
                end
            else
                jobid = NaN;
            end
        else
            jobid = NaN;
            tim = NaN;
        end
        
    end


end


