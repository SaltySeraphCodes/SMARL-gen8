class SessionTable { // Generic session table, if a racerID is supplied, it will filter to only that car

    constructor(_config, _data) {
      this.config = {
        parentElement: _config.parentElement,
        session_id: _config.session_id,
        racer_id: _config.racer_id || 0,
      }
      this.temp_data = _data

      this.initVis();
    }
  
    get_session_data(){ // Calls database to get session data
        console.log("getting data",this.temp_data,this.data);


        // temp json call
        return this.temp_data

    }

    initVis() {
      let vis = this;
      console
      vis.data = this.get_session_data()
      console.log("init",vis.data)
    
      vis.tableSection = d3.select(vis.config.parentElement)
  
      vis.updateVis(); //leave this empty for now...
      //vis.renderVis();
    }
  
  
    //We will add live Cars and live data 
   updateVis() { 
        let vis = this;
        //console.log("vis",vis.data,vis.data.length)
        // Just rebuild the whole table here
        vis.sessionTable = document.createElement("table");
        vis.sessionTable.classList.add("table","table-hover","table-sm");
        let sessionHead = document.createElement("thead")
        sessionHead.innerHTML = `
            <tr>
            <th scope="col">Lap</th>
            <th scope="col">Name</th>
            <th scope="col">S1</th>
            <th scope="col">S2</th>
            <th scope="col">S3</th>
            <th scope="col">Time</th>
            <th scope="col">Top Speed</th>
            <th scope="col">Average Speed</th>
            </tr>`
        vis.sessionTable.appendChild(sessionHead)
        let sessionBody = document.createElement("tbody");
        // meat of the table based on racer_Id
        for (let i = 0; i < vis.data.length; i ++) {
            let lap = vis.data[i];
            if (vis.config.racer_id == 0 || vis.config.racer_id == lap.racer_id) { // if catchall or matching racer
                let lapRow = document.createElement("tr")
                lapRow.innerHTML = `
                    <th scope="row"> ${lap.lap_number} </th>
                    <td> ${lap.racer_name} </td>
                    <td> ${lap.s1} </td>
                    <td> ${lap.s2} </td>
                    <td> ${lap.s3} </td>
                    <td> ${lap.lt} </td>
                    <td> ${lap.ts} </td>
                    <td> ${lap.as} </td>`
                sessionBody.appendChild(lapRow);
                //console.log("Adding",i,lapRow)
            }
        }
        vis.sessionTable.appendChild(sessionBody)  
      vis.renderVis();
   }
  

    renderVis() {
        let vis = this;
        vis.tableSection.append(function() {
            return vis.sessionTable;
        })

    }
  
  }